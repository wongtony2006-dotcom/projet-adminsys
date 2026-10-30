#!/usr/bin/env bash
# verifier.sh — teste chaque exigence du cahier des charges Pixelia et affiche OK/KO.
# Une fonction test_<ID>_… par exigence ; tests positifs ET négatifs (refus attendus).
# Ne modifie pas le système : seuls des fichiers de test temporaires, supprimés à la fin.
# Usage : sudo ./verifier.sh        Code de sortie : 0 si tout est conforme, 1 sinon.
set -u            # ni -e (le 1er KO arrêterait tout) ni pipefail (faux KO avec grep -q)
export LC_ALL=C   # messages des commandes en anglais, quelle que soit la langue du système

DOSSIER_PROJET="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly DOSSIER_PROJET
readonly CSV="$DOSSIER_PROJET/comptes.csv"
readonly SAUV=/sauvegardes
readonly SCRIPT_LOGS=/usr/local/sbin/analyse_logs.sh
readonly FIN_FREELANCE=2027-01-31   # fin de mission des freelances, comme dans creer_comptes.sh
# SSH (22) + sockets du client DHCP dhcpcd (68 en IPv4, 546 en IPv6) : ce ne sont pas des
# services, ils servent à obtenir l'adresse IP ; le pare-feu rejette tout trafic non sollicité
readonly ECOUTES_AUTORISEES=':22$|:68$|:546$'
readonly SYSCTL_PROJET="$DOSSIER_PROJET/config/sysctl.d/99-zz-projet.conf"
readonly MODULES_PROJET="$DOSSIER_PROJET/config/modprobe.d/projet.conf"

REUSSIS=0
TOTAL=0
FICHIERS_TEMP=()
SSHD_T=""

# ---------- affichage ----------
ok() { echo "[OK] $1 $2"; REUSSIS=$((REUSSIS + 1)); TOTAL=$((TOTAL + 1)); }
ko() { echo "[KO] $1 $2"; TOTAL=$((TOTAL + 1)); }
nettoyer() { rm -rf -- "${FICHIERS_TEMP[@]}"; }

# ---------- outils ----------
lignes_csv() { tail -n +2 "$CSV" | tr -d '\r' | grep -v '^[[:space:]]*$'; }

premier_du_groupe() {   # premier login du CSV dont le groupe principal est $1
    lignes_csv | awk -F';' -v g="$1" '$3 == g {print $1; exit}'
}

membres_groupe() {      # membres principaux (/etc/passwd) ET secondaires (/etc/group)
    local gid; gid=$(getent group "$1" | cut -d: -f3)
    { getent passwd | awk -F: -v gid="$gid" '$4 == gid {print $1}'
      getent group "$1" | cut -d: -f4 | tr ',' '\n'; } | grep -v '^$' | sort -u
}

peut_lister() { sudo -u "$1" ls "$2" >/dev/null 2>&1; }

peut_ecrire() {         # crée puis supprime un fichier de test
    local f="$2/.verif_$$_$1"
    if sudo -u "$1" touch "$f" 2>/dev/null; then rm -f "$f"; return 0; fi
    return 1
}

# droit_attendu <groupe> <répertoire> <rw|r|->  (testé avec le 1er compte du groupe)
droit_attendu() {
    local u lit=non ecrit=non
    u=$(premier_du_groupe "$1")
    peut_lister "$u" "$2" && lit=oui
    peut_ecrire "$u" "$2" && ecrit=oui
    case $3 in
        rw) [[ $lit == oui && $ecrit == oui ]] ;;
        r)  [[ $lit == oui && $ecrit == non ]] ;;
        -)  [[ $lit == non && $ecrit == non ]] ;;
    esac
}

# verifier_repertoire <répertoire> <groupe:droit>...
verifier_repertoire() {
    local rep=$1 paire; shift
    for paire in "$@"; do
        if ! droit_attendu "${paire%%:*}" "$rep" "${paire#*:}"; then
            ko C2 "$rep : le groupe ${paire%%:*} n'a pas le droit attendu (${paire#*:})"; return
        fi
    done
    ok C2 "$rep conforme ($*)"
}

sshd_option() { grep -i "^$1 " <<< "$SSHD_T" | head -n 1 | cut -d' ' -f2-; }

versions() { find "$SAUV" -mindepth 1 -maxdepth 1 -type d -name '20*' ! -name '*.encours' 2>/dev/null | sort; }

fs_reels() { findmnt -rn -o TARGET -t ext4,ext3,ext2,xfs,btrfs,vfat; }

# ---------- C : comptes et droits ----------
test_C1_comptes() {
    local login gp gs g
    while IFS=';' read -r login _ gp gs; do
        id "$login" >/dev/null 2>&1 || { ko C1 "compte absent : $login"; return; }
        [[ $(id -gn "$login") == "$gp" ]] || { ko C1 "$login : mauvais groupe principal"; return; }
        IFS=',' read -ra sec <<< "$gs"
        for g in "${sec[@]}"; do
            [[ " $(id -nG "$login") " == *" $g "* ]] || { ko C1 "$login n'est pas dans $g"; return; }
        done
    done < <(lignes_csv)
    ok C1 "chaque compte de comptes.csv existe avec les bons groupes"
}

test_C1_doublons() {
    if [[ -z $(cut -d: -f1 /etc/passwd | sort | uniq -d) && -z $(cut -d: -f1 /etc/group | sort | uniq -d) ]]; then
        ok C1 "aucun compte ni groupe en double"
    else ko C1 "doublons dans /etc/passwd ou /etc/group"; fi
}

# Particularité du contexte A : TOUS les membres de freelance expirent à la date fixée
test_C1_freelance() {
    local u membres attendu
    attendu=$(date -d "$FIN_FREELANCE" '+%b %d, %Y')   # format de chage -l (LC_ALL=C)
    membres=$(membres_groupe freelance)
    [[ -n $membres ]] || { ko C1 "groupe freelance vide ou absent"; return; }
    for u in $membres; do
        chage -l "$u" | grep -q "^Account expires[[:space:]]*: $attendu$" \
            || { ko C1 "le compte freelance $u n'expire pas le $FIN_FREELANCE"; return; }
    done
    ok C1 "comptes freelance expirés automatiquement le $FIN_FREELANCE ($(xargs <<< "$membres"))"
}

# Tableau C2 de Pixelia : rw = lecture/écriture, r = lecture seule, - = aucun accès
test_C2_projets()   { verifier_repertoire /srv/projets         dev:rw design:r  commercial:-  freelance:-; }
test_C2_externe()   { verifier_repertoire /srv/projets/externe dev:rw design:r  commercial:-  freelance:rw; }
test_C2_maquettes() { verifier_repertoire /srv/maquettes       dev:r  design:rw commercial:r  freelance:-; }
test_C2_clients()   { verifier_repertoire /srv/clients         dev:-  design:-  commercial:rw freelance:-; }

test_C2_acl_par_defaut() {
    local f="/srv/projets/.verif_heritage_$$"
    FICHIERS_TEMP+=("$f")
    sudo -u "$(premier_du_groupe dev)" touch "$f" 2>/dev/null
    if sudo -u "$(premier_du_groupe design)" test -r "$f"; then
        ok C2 "ACL par défaut : un fichier créé par un dev est lisible par design"
    else ko C2 "ACL par défaut absente ou incorrecte sur /srv/projets"; fi
}

test_C3_admins() {
    local u
    for u in $(membres_groupe admins); do
        sudo -l -U "$u" | grep -q '(ALL : ALL) ALL' || { ko C3 "$u (admins) n'a pas sudo"; return; }
    done
    ok C3 "les membres de admins ont sudo"
}

test_C3_support() {
    local regles
    regles=$(sudo -l -U support | sed -n '/may run the following/,$p' | tail -n +2)
    if [[ $(grep -c . <<< "$regles") -eq 1 && $regles == *"NOPASSWD: $SCRIPT_LOGS"* ]]; then
        ok C3 "support ne peut lancer que analyse_logs.sh en root"
    else ko C3 "règles sudo de support non conformes"; fi
}

test_C3_personne_dautre() {
    local u uid
    while IFS=: read -r u _ uid _; do
        (( uid >= 1000 && uid < 60000 )) || continue
        [[ $u == support || " $(id -nG "$u") " == *" admins "* ]] && continue
        sudo -l -U "$u" | grep -q 'is not allowed to run sudo' || { ko C3 "$u a des droits sudo"; return; }
    done < /etc/passwd
    [[ -z $(getent group sudo | cut -d: -f4) ]] || { ko C3 "le groupe sudo a des membres"; return; }
    ok C3 "aucun autre compte n'a sudo"
}

test_C3_script_protege() {
    if [[ $(stat -c %U "$SCRIPT_LOGS") == root && $(stat -c %U /usr/local/sbin) == root ]] \
        && [[ -z $(find "$SCRIPT_LOGS" /usr/local/sbin -maxdepth 0 -perm /022) ]]; then
        ok C3 "analyse_logs.sh et son dossier : propriété de root, modifiables par root seul"
    else ko C3 "analyse_logs.sh ou /usr/local/sbin modifiable par un autre que root"; fi
}

test_C4_root() {
    local mdp; mdp=$(getent shadow root | cut -d: -f2)
    if [[ $mdp == '!'* || $mdp == '*'* ]]; then ok C4 "compte root verrouillé"
    else ko C4 "compte root non verrouillé"; fi
}

test_C4_homes() {
    local d
    for d in /home/*/; do
        [[ $(stat -c %a "$d") == 700 ]] || { ko C4 "$d n'est pas en 700"; return; }
    done
    ok C4 "répertoires personnels en 700"
}

# ---------- S : SSH ----------
test_S1_config() {
    if [[ $(sshd_option passwordauthentication) == no && $(sshd_option kbdinteractiveauthentication) == no \
          && $(sshd_option pubkeyauthentication) == yes ]]; then
        ok S1 "authentification par clé uniquement"
    else ko S1 "mot de passe ou keyboard-interactive encore autorisé"; fi
}

test_S1_refus_mot_de_passe() {   # vraie tentative en local, sans clé
    local sortie
    sortie=$(ssh -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password \
                 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                 support@127.0.0.1 true 2>&1)
    if [[ $sortie == *"Permission denied (publickey)"* ]]; then ok S1 "connexion par mot de passe refusée (test réel)"
    else ko S1 "réponse inattendue du serveur SSH"; fi
}

test_S2() {
    if [[ $(sshd_option permitrootlogin) == no ]]; then ok S2 "connexion root refusée"
    else ko S2 "PermitRootLogin n'est pas à no"; fi
}

test_S3() {
    if [[ $(sshd_option allowgroups) == acces_ssh ]]; then ok S3 "seul le groupe acces_ssh peut se connecter"
    else ko S3 "AllowGroups différent de acces_ssh"; fi
}

test_S4_essais() {
    local n; n=$(sshd_option maxauthtries)
    if [[ -n $n ]] && (( n <= 4 )); then ok S4 "MaxAuthTries = $n (4 au plus)"
    else ko S4 "MaxAuthTries = ${n:-?} (4 au plus attendu)"; fi
}

test_S4_inactivite() {
    local ct i c
    ct=$(sshd_option channeltimeout); i=$(sshd_option clientaliveinterval); c=$(sshd_option clientalivecountmax)
    if [[ -n $ct && $ct != none ]] && (( i > 0 && c > 0 && i * c <= 900 )); then
        ok S4 "inactivité limitée (ChannelTimeout $ct, client muet coupé après $((i * c)) s)"
    else ko S4 "délai d'inactivité absent ou supérieur à 15 minutes"; fi
}

test_S5() {
    if sshd -t 2>/dev/null && [[ -f /etc/ssh/sshd_config.d/50-projet.conf ]]; then
        ok S5 "configuration dans sshd_config.d, validée par sshd -t"
    else ko S5 "sshd -t échoue ou fichier 50-projet.conf absent"; fi
}

# ---------- J : journaux et défense ----------
test_J1() {
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok J1 "fail2ban : jail sshd active (bannissement après $(fail2ban-client get sshd maxretry) échecs)"
    else ko J1 "fail2ban arrêté ou jail sshd inactive"; fi
}

test_J2_politique() {
    if nft list chain inet filtre entree 2>/dev/null | grep -q 'policy drop'; then
        ok J2 "pare-feu : politique par défaut drop en entrée"
    else ko J2 "politique par défaut différente de drop, ou table absente"; fi
}

test_J2_ssh_et_etablies() {
    local regles; regles=$(nft list chain inet filtre entree 2>/dev/null)
    if [[ $regles == *"tcp dport 22"*accept* && $regles == *"established,related accept"* ]]; then
        ok J2 "pare-feu : SSH et connexions établies autorisés"
    else ko J2 "règle SSH ou connexions établies manquante"; fi
}

test_J2_persistant() {
    # la chaîne d'entrée précisément : « policy drop » figure aussi dans la chaîne transfert
    if [[ $(systemctl is-enabled nftables 2>/dev/null) == enabled ]] \
        && grep -qE 'hook input .*policy drop' /etc/nftables.conf; then
        ok J2 "pare-feu rechargé au démarrage (service nftables activé)"
    else ko J2 "le pare-feu ne survivra pas à un redémarrage"; fi
}

test_J3() {   # dernière valeur lue = valeur appliquée (un fichier ajouté après le nôtre l'emporte)
    local stockage; stockage=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep '^Storage=' | tail -n 1)
    if [[ $stockage == Storage=persistent && -d /var/log/journal ]]; then
        ok J3 "journal persistant ($(journalctl --list-boots 2>/dev/null | wc -l) démarrage(s) conservé(s))"
    else ko J3 "journal non persistant"; fi
}

test_J4() {
    local c1 c2 c3
    "$SCRIPT_LOGS" -s 1000000 >/dev/null 2>&1; c1=$?
    "$SCRIPT_LOGS" -s 0 >/dev/null 2>&1; c2=$?
    "$SCRIPT_LOGS" -s abc >/dev/null 2>&1; c3=$?
    if (( c1 == 0 && c2 == 1 && c3 == 2 )); then ok J4 "analyse_logs.sh : code 0 sous le seuil, 1 au-dessus, 2 si erreur"
    else ko J4 "codes de sortie $c1 $c2 $c3 (attendus : 0 1 2)"; fi
}

# ---------- B : sauvegardes ----------
test_B1_versions() {
    local n; n=$(versions | grep -c .)
    if (( n >= 1 && n <= 7 )); then ok B1 "$n version(s) datée(s), 7 au plus"
    else ko B1 "$n version(s) : attendu entre 1 et 7"; fi
}

test_B1_incremental() {
    local v; mapfile -t v < <(versions)
    (( ${#v[@]} >= 2 )) || { ko B1 "une seule version : lance « sudo systemctl start sauvegarde.service » puis relance verifier.sh"; return; }
    if [[ $(stat -c %i "${v[-2]}/etc/hostname") == "$(stat -c %i "${v[-1]}/etc/hostname")" ]]; then
        ok B1 "incrémental : fichier inchangé partagé entre deux versions (même inode)"
    else ko B1 "fichier inchangé recopié : --link-dest inactif"; fi
}

test_B1_acl() {
    local v; v=$(versions | tail -n 1)
    if [[ -n $v ]] && getfacl -p "$v/srv/projets" 2>/dev/null | grep -q '^group:dev:rwx'; then
        ok B1 "ACL conservées dans la sauvegarde"
    else ko B1 "ACL absentes de la dernière sauvegarde"; fi
}

test_B2() {
    if [[ $(systemctl is-enabled sauvegarde.timer 2>/dev/null) == enabled ]] \
        && journalctl -u sauvegarde.service --no-pager 2>/dev/null | grep -q 'version créée'; then
        ok B2 "sauvegarde planifiée (timer actif) et journalisée"
    else ko B2 "timer inactif ou aucune exécution dans le journal"; fi
}

test_B3() {
    if [[ $(stat -c '%U:%G %a' "$SAUV") == "root:admins 750" ]] && ! peut_lister "$(premier_du_groupe dev)" "$SAUV"; then
        ok B3 "sauvegardes accessibles aux seuls administrateurs"
    else ko B3 "droits de $SAUV non conformes"; fi
}

test_B4() {
    local v tmp; v=$(versions | tail -n 1)
    [[ -n $v ]] || { ko B4 "aucune version à restaurer"; return; }
    tmp=$(mktemp -d); FICHIERS_TEMP+=("$tmp")
    if rsync -aAX "$v/etc/hostname" "$tmp/" && cmp -s "$tmp/hostname" /etc/hostname \
        && grep -qi 'restauration' "$DOSSIER_PROJET/DOSSIER.md"; then
        ok B4 "restauration d'un fichier réussie, procédure documentée"
    else ko B4 "restauration impossible ou procédure absente de DOSSIER.md"; fi
}

# ---------- D : système ----------
test_D1() {
    if apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"' \
        && [[ $(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null) == enabled ]]; then
        ok D1 "mises à jour de sécurité automatiques actives"
    else ko D1 "unattended-upgrades non configuré"; fi
}

test_D2() {
    local autres
    autres=$(ss -Htuln | awk '{print $5}' | grep -vE '^(127\.|\[::1\]|::1)' | grep -vE "$ECOUTES_AUTORISEES")
    if [[ -z $autres ]]; then ok D2 "seul SSH écoute sur le réseau"
    else ko D2 "écoutes en plus de SSH : $(tr '\n' ' ' <<< "$autres")"; fi
}

test_D3_ecriture() {
    local fs trouves=""
    for fs in $(fs_reels); do
        trouves+=$(find "$fs" -xdev \( -type f -perm -0002 -o -type d -perm -0002 ! -perm -1000 \) -print 2>/dev/null)
    done
    if [[ -z $trouves ]]; then ok D3 "aucun fichier modifiable par tous hors répertoires temporaires"
    else ko D3 "modifiables par tous : $(head -n 3 <<< "$trouves" | tr '\n' ' ')"; fi
}

test_D3_suid() {
    local fs actuels nouveaux
    actuels=$(for fs in $(fs_reels); do
                  find "$fs" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null
              done | sort)
    nouveaux=$(comm -23 <(echo "$actuels") <(sort "$DOSSIER_PROJET/config/suid_attendus.txt"))
    if [[ -z $nouveaux ]]; then ok D3 "aucun SUID/SGID en dehors de la liste justifiée"
    else ko D3 "SUID/SGID non prévus : $(tr '\n' ' ' <<< "$nouveaux")"; fi
}

# ---------- bonus : recommandations ANSSI supplémentaires ----------
# Chaque « clé = valeur » du fichier du dépôt doit être en vigueur. Un « * » dans la clé
# vaut pour toutes les cartes réseau (net.ipv4.conf.*.rp_filter : all, default, lo…).
test_R9_R14_noyau() {
    local cle valeur f actuel n=0 ecarts=""
    while read -r cle _ valeur; do
        for f in /proc/sys/${cle//./\/}; do
            n=$((n + 1))
            actuel=$(cat "$f" 2>/dev/null); actuel=${actuel//$'\t'/ }
            [[ $actuel == "$valeur" ]] || ecarts+=" ${f#/proc/sys/}=${actuel:-?}"
        done
    done < <(grep -E '^[a-z]' "$SYSCTL_PROJET")
    if [[ -z $ecarts ]]; then ok R9-R14 "$n paramètres du noyau conformes (sysctl)"
    else ko R9-R14 "paramètres du noyau différents :$(cut -c 1-150 <<< "$ecarts")"; fi
}

test_R9_R14_persistant() {
    if cmp -s "$SYSCTL_PROJET" /etc/sysctl.d/99-zz-projet.conf; then
        ok R9-R14 "paramètres du noyau réappliqués à chaque démarrage (/etc/sysctl.d)"
    else ko R9-R14 "/etc/sysctl.d/99-zz-projet.conf absent ou différent du dépôt"; fi
}

test_R10_modules() {   # modprobe -n : simulation, aucun module n'est réellement chargé
    local m
    for m in $(awk '$1 == "install" {print $2}' "$MODULES_PROJET"); do
        # /proc/modules écrit les noms avec « _ » (usb-storage y devient usb_storage)
        if ! modprobe -n -v "$m" 2>/dev/null | grep -q 'install /bin/false' || grep -qs "^${m//-/_} " /proc/modules; then
            ko R10 "le module $m peut être chargé, ou l'est déjà"; return
        fi
    done
    ok R10 "modules inutiles impossibles à charger : $(awk '$1 == "install" {print $2}' "$MODULES_PROJET" | xargs)"
}

test_R28_tmp() {        # vrai essai : un programme copié dans /tmp ne doit pas démarrer
    local options prog="/tmp/.verif_exec_$$"
    options=",$(findmnt -no OPTIONS /tmp 2>/dev/null),"
    FICHIERS_TEMP+=("$prog")
    if [[ $options == *,nosuid,* && $options == *,nodev,* && $options == *,noexec,* ]] \
        && cp /usr/bin/true "$prog" && ! "$prog" 2>/dev/null \
        && systemctl cat tmp.mount 2>/dev/null | grep '^Options=' | tail -n 1 | grep -q noexec; then
        ok R28 "/tmp monté nosuid,nodev,noexec : un programme copié dans /tmp ne se lance pas"
    else ko R28 "/tmp sans nosuid, nodev ou noexec (maintenant ou au prochain démarrage)"; fi
}

test_R36_umask() {      # umask réellement obtenu par un compte en ouvrant une session
    local u m; u=$(premier_du_groupe dev); m=$(sudo -u "$u" sh -c umask 2>/dev/null)
    if grep -qE '^UMASK[[:space:]]+027$' /etc/login.defs && [[ $m == 0027 ]]; then
        ok R36 "umask 027 dans les sessions (testé avec $u)"
    else ko R36 "umask de $u : ${m:-?} (0027 attendu, UMASK dans /etc/login.defs)"; fi
}

test_ALGO_ssh() {       # vraies tentatives en local, chacune avec un seul algorithme faible
    local essai sortie
    for essai in "KexAlgorithms=ecdh-sha2-nistp256:key exchange" "MACs=hmac-sha1:MAC" \
                 "HostKeyAlgorithms=ecdsa-sha2-nistp256:host key type"; do
        sortie=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                     -o ConnectTimeout=5 -o Ciphers=aes128-ctr -o "${essai%%:*}" support@127.0.0.1 true 2>&1)
        [[ $sortie == *"no matching ${essai#*:}"* ]] || { ko ALGO "algorithme faible accepté : ${essai%%:*}"; return; }
    done
    ok ALGO "SSH refuse les courbes NIST, SHA-1 et la clé d'hôte ECDSA (tests réels)"
}

# ---------- programme principal ----------
TESTS=(
    test_C1_comptes test_C1_doublons test_C1_freelance
    test_C2_projets test_C2_externe test_C2_maquettes test_C2_clients test_C2_acl_par_defaut
    test_C3_admins test_C3_support test_C3_personne_dautre test_C3_script_protege
    test_C4_root test_C4_homes
    test_S1_config test_S1_refus_mot_de_passe test_S2 test_S3 test_S4_essais test_S4_inactivite test_S5
    test_J1 test_J2_politique test_J2_ssh_et_etablies test_J2_persistant test_J3 test_J4
    test_B1_versions test_B1_incremental test_B1_acl test_B2 test_B3 test_B4
    test_D1 test_D2 test_D3_ecriture test_D3_suid
    test_R9_R14_noyau test_R9_R14_persistant test_R10_modules test_R28_tmp test_R36_umask test_ALGO_ssh
)

main() {
    [[ $EUID -eq 0 ]] || { echo "À lancer en root (sudo $0)" >&2; exit 1; }
    trap nettoyer EXIT
    SSHD_T=$(sshd -T 2>/dev/null)
    local t
    for t in "${TESTS[@]}"; do "$t"; done
    echo "--- $REUSSIS / $TOTAL tests réussis"
    if (( REUSSIS == TOTAL )); then exit 0; else exit 1; fi
}

main "$@"
