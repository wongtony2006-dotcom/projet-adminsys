#!/usr/bin/env bash
# installer.sh — reconstruit toute la configuration du serveur Pixelia depuis le dépôt.
# Fonctionne sur la VM vierge comme sur une VM déjà configurée : relançable sans danger.
# Ordre choisi pour ne jamais se bloquer dehors : comptes et clés d'abord, durcissement
# SSH ensuite, verrouillage de root en dernier.
# Usage : sudo ./installer.sh
# Codes de sortie : 0 = succès, 1 = erreur
set -euo pipefail

DOSSIER_PROJET="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly DOSSIER_PROJET
readonly CONFIG="$DOSSIER_PROJET/config"
readonly PAQUETS=(sudo acl rsync nftables fail2ban unattended-upgrades apt-listchanges)
readonly DISQUE=/dev/sdb               # second disque de la VM, dédié aux sauvegardes
readonly POINT_MONTAGE=/sauvegardes
readonly ETIQUETTE=SAUVEGARDE
# D3 — programmes SUID root inutiles sur ce serveur (changer son nom complet ou son shell,
# authentification SSH « hostbased ») : le bit SUID leur est retiré
readonly SUID_INUTILES=(/usr/bin/chfn /usr/bin/chsh /usr/lib/openssh/ssh-keysign)

erreur() { echo "ERREUR : $*" >&2; exit 1; }
etape()  { echo; echo "=== $* ==="; }

verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root (sudo $0)"
    [[ -f $DOSSIER_PROJET/comptes.csv && -d $CONFIG ]] \
        || erreur "lance le script depuis le dépôt complet"
}

# membres_groupe <groupe> : membres principaux (/etc/passwd) ET secondaires (/etc/group)
membres_groupe() {
    local gid
    gid=$(getent group "$1" | cut -d: -f3)
    {
        getent passwd | awk -F: -v gid="$gid" '$4 == gid {print $1}'
        getent group "$1" | cut -d: -f4 | tr ',' '\n'
    } | grep -v '^$' | sort -u
}

installer_paquets() {
    export DEBIAN_FRONTEND=noninteractive    # aucune question pendant l'installation
    apt-get update
    apt-get install -y "${PAQUETS[@]}"
}

# Fichiers des premières versions du projet, remplacés par 10-projet et 50-projet.conf
retirer_anciens_fichiers() {
    rm -f /etc/sudoers.d/admins /etc/ssh/sshd_config.d/durcissement.conf
}

# C3 — règles sudo du projet ; personne d'autre dans le groupe sudo
configurer_sudo() {
    local f="$CONFIG/sudoers.d/10-projet" u
    visudo -cf "$f" >/dev/null || erreur "syntaxe sudoers invalide : $f"
    install -m 0440 -o root -g root "$f" /etc/sudoers.d/10-projet
    for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
        gpasswd -d "$u" sudo
    done
}

# Un administrateur sans mot de passe n'aurait ni sudo ni accès console de secours
mots_de_passe_admins() {
    local u etat
    for u in $(membres_groupe admins); do
        etat=$(passwd -S "$u" | awk '{print $2}')   # P = utilisable, L = verrouillé, NP = vide
        if [[ $etat != P ]]; then
            if [[ -t 0 ]]; then
                echo "Mot de passe de l'administrateur $u (sudo et console de secours) :"
                passwd "$u" || echo "ATTENTION : mot de passe de $u non défini" >&2
            else
                echo "ATTENTION : $u n'a pas de mot de passe utilisable" >&2
            fi
        fi
    done
}

# Scripts lancés en root : propriété de root, non modifiables par les autres
installer_scripts() {
    chown root:root /usr/local/sbin
    chmod 0755 /usr/local/sbin
    install -o root -g root -m 0755 "$DOSSIER_PROJET/analyse_logs.sh" /usr/local/sbin/
    install -o root -g root -m 0755 "$DOSSIER_PROJET/sauvegarde.sh" /usr/local/sbin/
}

# S5 — refuse de durcir SSH si aucun administrateur ne pourra se reconnecter
verifier_acces_admin() {
    local u
    for u in $(membres_groupe admins); do
        if [[ " $(id -nG "$u") " == *" acces_ssh "* && -s /home/$u/.ssh/authorized_keys ]]; then
            return 0
        fi
    done
    erreur "aucun administrateur avec une clé dans acces_ssh : durcissement SSH annulé"
}

# S1 à S5 — fichier dans sshd_config.d, validé par sshd -t avant le redémarrage
configurer_ssh() {
    verifier_acces_admin
    install -m 0644 -o root -g root "$CONFIG/ssh/sshd_config.d/50-projet.conf" /etc/ssh/sshd_config.d/
    if ! sshd -t; then
        rm -f /etc/ssh/sshd_config.d/50-projet.conf
        erreur "configuration SSH invalide : fichier retiré, service non redémarré"
    fi
    systemctl restart ssh      # les sessions déjà ouvertes ne sont pas coupées
}

# J3 — journal conservé sur disque
configurer_journal() {
    install -D -m 0644 "$CONFIG/journald.conf.d/persistent.conf" \
        /etc/systemd/journald.conf.d/persistent.conf
    systemctl restart systemd-journald
}

# J2 — pare-feu chargé au démarrage
configurer_parefeu() {
    nft -c -f "$CONFIG/nftables.conf" || erreur "nftables.conf invalide"
    install -m 0644 "$CONFIG/nftables.conf" /etc/nftables.conf
    systemctl enable nftables
    systemctl restart nftables
}

# J1 — APRÈS le pare-feu : redémarrer nftables efface la table de fail2ban
configurer_fail2ban() {
    install -m 0644 "$CONFIG/fail2ban/jail.d/sshd-projet.conf" /etc/fail2ban/jail.d/
    systemctl enable fail2ban
    systemctl restart fail2ban
}

# D1 — mises à jour de sécurité quotidiennes
configurer_mises_a_jour() {
    install -m 0644 "$CONFIG/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable apt-daily.timer apt-daily-upgrade.timer
}

# B1, B3 — second disque formaté UNIQUEMENT s'il est vide, monté par étiquette
preparer_disque() {
    if ! blkid -L "$ETIQUETTE" >/dev/null; then
        [[ -b $DISQUE ]] || erreur "disque $DISQUE introuvable"
        if blkid "$DISQUE" >/dev/null || [[ $(lsblk -nr -o NAME "$DISQUE" | wc -l) -gt 1 ]]; then
            erreur "$DISQUE contient déjà des données : rien n'est formaté"
        fi
        printf 'label: gpt\n,,L\n' | sfdisk "$DISQUE"   # une partition sur tout le disque
        udevadm settle
        mkfs.ext4 -q -L "$ETIQUETTE" "${DISQUE}1"
    fi
    install -d "$POINT_MONTAGE"
    if ! grep -q "^LABEL=$ETIQUETTE " /etc/fstab; then
        echo "LABEL=$ETIQUETTE $POINT_MONTAGE ext4 defaults,nofail,nodev,nosuid,noexec 0 2" >> /etc/fstab
        systemctl daemon-reload
    fi
    mountpoint -q "$POINT_MONTAGE" || mount "$POINT_MONTAGE"
    # B3 : APRÈS le montage, sinon on modifie le dossier caché sous le disque
    chown root:admins "$POINT_MONTAGE"
    chmod 0750 "$POINT_MONTAGE"
}

# B2 — sauvegarde quotidienne par timer systemd ; première sauvegarde tout de suite
configurer_sauvegarde() {
    preparer_disque
    install -m 0644 "$CONFIG/systemd/sauvegarde.service" \
        "$CONFIG/systemd/sauvegarde.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer
    if [[ -z $(find "$POINT_MONTAGE" -mindepth 1 -maxdepth 1 -name '20*' -print -quit) ]]; then
        systemctl start sauvegarde.service
    fi
}

# C4 — root verrouillé, répertoires personnels en 0700 (aussi pour les futurs comptes)
verrouiller_root_et_homes() {
    passwd -l root >/dev/null
    chmod 700 /home/*/
    if grep -q '^HOME_MODE' /etc/login.defs; then
        sed -i 's/^HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
}

# D3 — retrait du bit SUID ; dpkg-statoverride conserve le réglage lors des mises à jour
retirer_suid_inutiles() {
    local f
    for f in "${SUID_INUTILES[@]}"; do
        [[ -e $f ]] || continue
        if ! dpkg-statoverride --list "$f" >/dev/null; then
            dpkg-statoverride --update --add root root 0755 "$f"
        fi
    done
}

main() {
    verifier_prerequis
    etape "1. Paquets";                                installer_paquets
    etape "2. Comptes, groupes, clés, /srv (C1, C2)";  bash "$DOSSIER_PROJET/creer_comptes.sh"
    etape "3. sudo (C3)";                              configurer_sudo; retirer_anciens_fichiers
    etape "4. Mots de passe des administrateurs";      mots_de_passe_admins
    etape "5. Scripts dans /usr/local/sbin";           installer_scripts
    etape "6. SSH (S1 à S5)";                          configurer_ssh
    etape "7. Journal persistant (J3)";                configurer_journal
    etape "8. Pare-feu (J2)";                          configurer_parefeu
    etape "9. fail2ban (J1)";                          configurer_fail2ban
    etape "10. Mises à jour automatiques (D1)";        configurer_mises_a_jour
    etape "11. Disque et sauvegardes (B1 à B3)";       configurer_sauvegarde
    etape "12. Root et répertoires personnels (C4)";  verrouiller_root_et_homes
    etape "13. Bits SUID inutiles (D3)";               retirer_suid_inutiles
    etape "14. Vérification";                          bash "$DOSSIER_PROJET/verifier.sh" || true
}

main "$@"
