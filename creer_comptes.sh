#!/usr/bin/env bash
# creer_comptes.sh — crée les groupes, les comptes, les clés SSH et les répertoires
# partagés de /srv à partir de comptes.csv (exigences C1, C2 et C4).
# Idempotent : le relancer remet le système dans l'état décrit par le CSV.
# Usage : sudo ./creer_comptes.sh [chemin/vers/comptes.csv]
# Codes de sortie : 0 = succès, 1 = erreur
set -euo pipefail

DOSSIER_PROJET="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly DOSSIER_PROJET
readonly CSV="${1:-$DOSSIER_PROJET/comptes.csv}"
readonly DOSSIER_CLES="$DOSSIER_PROJET/config/cles"
readonly ENTETE="login;nom;groupe_principal;groupes_secondaires"
readonly DATE_FIN_FREELANCE="2027-01-31"   # fin de mission des freelances (contexte A)

erreur() { echo "ERREUR : $*" >&2; exit 1; }
info()   { echo "[*] $*"; }

verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root (sudo $0)"
    [[ -r $CSV ]]     || erreur "fichier introuvable : $CSV"
    [[ "$(head -n 1 "$CSV" | tr -d '\r')" == "$ENTETE" ]] \
        || erreur "en-tête attendu dans $CSV : $ENTETE"
}

# Lignes utiles du CSV : sans en-tête, sans \r (fichier édité sous Windows), sans ligne vide
lignes_csv() {
    tail -n +2 "$CSV" | tr -d '\r' | grep -v '^[[:space:]]*$' || true
}

creer_groupe() {
    if ! getent group "$1" >/dev/null; then
        groupadd "$1"
        info "groupe créé : $1"
    fi
}

creer_groupes() {
    local login nom gp gs g
    creer_groupe acces_ssh
    while IFS=';' read -r login nom gp gs; do
        creer_groupe "$gp"
        IFS=',' read -ra secondaires <<< "$gs"
        for g in "${secondaires[@]}"; do creer_groupe "$g"; done
    done < <(lignes_csv)
}

# Comptes non administrateurs : aucun mot de passe utilisable, connexion par clé uniquement.
# Corrige aussi les comptes créés par une version précédente du script (mot de passe
# temporaire commun + changement forcé, qui bloquait la connexion par clé et sudo).
retirer_mot_de_passe() {
    local login=$1
    if [[ $(passwd -S "$login" | awk '{print $2}') == P ]]; then
        usermod -p '!' "$login"
        info "mot de passe retiré : $login"
    fi
    # Date de dernier changement à 0 = « changement obligatoire » : bloquerait la connexion
    if [[ $(getent shadow "$login" | cut -d: -f3) == 0 ]]; then
        chage -d "$(date +%F)" "$login"
    fi
}

creer_compte() {
    local login=$1 nom=$2 gp=$3 gs=$4
    if id -u "$login" >/dev/null 2>&1; then
        # -G REMPLACE la liste des groupes secondaires : le compte revient exactement
        # à ce que dit le CSV (et sort du groupe sudo s'il y était)
        usermod -g "$gp" -G "$gs" -c "$nom" -s /bin/bash "$login"
    else
        local opts=(-m -g "$gp" -c "$nom" -s /bin/bash)
        if [[ -n $gs ]]; then opts+=(-G "$gs"); fi
        useradd "${opts[@]}" "$login"
        info "compte créé : $login"
    fi
    chmod 700 "/home/$login"                      # C4 : home illisible par les autres
    if [[ $gp != admins ]]; then
        retirer_mot_de_passe "$login"
    fi
    if [[ $gp == freelance ]]; then
        chage -E "$DATE_FIN_FREELANCE" "$login"   # expiration automatique du compte
    fi
}

# Clé publique config/cles/<login>.pub -> ~/.ssh/authorized_keys (si elle existe)
installer_cle() {
    local login=$1 gp=$2
    local cle="$DOSSIER_CLES/$login.pub"
    if [[ -f $cle ]]; then
        install -d -m 700 -o "$login" -g "$gp" "/home/$login/.ssh"
        install -m 600 -o "$login" -g "$gp" "$cle" "/home/$login/.ssh/authorized_keys"
    fi
}

creer_comptes() {
    local login nom gp gs
    while IFS=';' read -r login nom gp gs; do
        [[ -n $login && -n $gp ]] || erreur "ligne invalide dans le CSV : '$login;$nom;$gp;$gs'"
        creer_compte "$login" "$nom" "$gp" "$gs"
        installer_cle "$login" "$gp"
    done < <(lignes_csv)
}

# appliquer_acl <répertoire> <ACL d'accès> [<ACL par défaut>]
# --set REMPLACE toute l'ACL : relancer le script efface aussi une entrée ajoutée à la main.
# L'ACL par défaut est héritée par les fichiers et dossiers créés ensuite.
appliquer_acl() {
    local rep=$1 acces=$2 defaut=${3:-$2}
    local base="u::rwx,g::---,o::---"
    install -d -o root -g root -m 0770 "$rep"
    setfacl --set "$base,$acces" "$rep"
    setfacl -d --set "$base,$defaut" "$rep"
}

# C2 — répertoires partagés de Pixelia (« - » = aucun droit)
#                    dev   design  commercial  freelance
# /srv/projets       rwx   r-x     -           --x (traverser vers externe)
# /srv/projets/externe rwx r-x     -           rwx
# /srv/maquettes     r-x   rwx     r-x         -
# /srv/clients       -     -       rwx         -
preparer_srv() {
    install -d -o root -g root -m 0755 /srv
    # freelance : --x pour TRAVERSER /srv/projets jusqu'à externe, sans pouvoir le lister.
    # Absent de l'ACL par défaut : les futurs sous-dossiers ne lui seront pas ouverts.
    appliquer_acl /srv/projets \
        "g:dev:rwx,g:design:r-x,g:freelance:--x" \
        "g:dev:rwx,g:design:r-x"
    appliquer_acl /srv/projets/externe "g:dev:rwx,g:design:r-x,g:freelance:rwx"
    appliquer_acl /srv/maquettes       "g:dev:r-x,g:design:rwx,g:commercial:r-x"
    appliquer_acl /srv/clients         "g:commercial:rwx"
}

main() {
    verifier_prerequis
    creer_groupes
    creer_comptes
    preparer_srv
    info "comptes et répertoires à jour"
}

main "$@"
