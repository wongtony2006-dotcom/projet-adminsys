#!/usr/bin/env bash
# audit.sh — mesure le durcissement avec Lynis, ssh-audit et verifier.sh (bonus).
# À lancer deux fois : sur la VM vierge AVANT installer.sh, puis APRÈS :
#   sudo ./audit.sh avant   ;   sudo ./installer.sh   ;   sudo ./audit.sh apres
# (avant « apres », lancer une 2e sauvegarde pour le test B1 : voir README.md)
# Rapports dans audits/ ; audits/resume.md compare les deux états.
# Lecture seule : n'installe que les deux outils, ne modifie aucun réglage.
# Usage : sudo ./audit.sh avant|apres
# Codes de sortie : 0 = audit fait, 1 = erreur, 2 = mauvaise utilisation
set -euo pipefail
export LC_ALL=C

DOSSIER_PROJET="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly DOSSIER_PROJET
readonly AUDITS="$DOSSIER_PROJET/audits"
readonly RAPPORT_LYNIS=/var/log/lynis-report.dat   # rapport machine de Lynis (clé=valeur)

erreur() { echo "ERREUR : $*" >&2; exit 1; }
usage()  { echo "Usage : sudo $0 avant|apres" >&2; exit 2; }

compter() { grep -c -- "$1" "$2" || true; }   # grep -c sort en 1 quand il compte 0

installer_outils() {
    if ! command -v lynis >/dev/null || ! command -v ssh-audit >/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        apt-get install -y -q lynis ssh-audit
    fi
}

# auditer <avant|apres> : rapports complets + mesures clés dans mesures-<état>.txt
auditer() {
    local etat=$1
    echo "Lynis (une à deux minutes)…"
    # Même sans couleurs, Lynis aligne son texte avec des codes « ESC[nC » (avancer de n
    # colonnes) : remplacés par n espaces pour que le rapport se lise dans un éditeur
    lynis audit system --quick --no-colors 2>&1 | perl -pe 's/\e\[(\d*)C/" " x ($1 || 1)/ge' \
        > "$AUDITS/lynis-$etat.txt" || erreur "Lynis a échoué : voir $AUDITS/lynis-$etat.txt"
    # Avertissements et suggestions : identifiant du test et texte
    grep -E '^(warning|suggestion)\[\]=' "$RAPPORT_LYNIS" | cut -d'|' -f1,2 \
        | sed -e 's/\[\]=/ /' -e 's/|/ : /' > "$AUDITS/lynis-$etat-points.txt" || true
    echo "ssh-audit…"
    # Code de sortie non nul dès qu'un point est signalé : ce n'est pas une erreur ici
    ssh-audit -n 127.0.0.1 > "$AUDITS/ssh-audit-$etat.txt" 2>&1 || true
    grep -q '^# general' "$AUDITS/ssh-audit-$etat.txt" \
        || erreur "ssh-audit n'a pas pu joindre le serveur SSH local"
    echo "verifier.sh…"
    bash "$DOSSIER_PROJET/verifier.sh" > "$AUDITS/verifier-$etat.txt" 2>&1 || true   # 1 = des KO
    {
        echo "date=$(date '+%d/%m/%Y %H:%M')"
        echo "indice=$(grep '^hardening_index=' "$RAPPORT_LYNIS" | cut -d= -f2)"
        echo "avertissements=$(compter '^warning\[\]=' "$RAPPORT_LYNIS")"
        echo "suggestions=$(compter '^suggestion\[\]=' "$RAPPORT_LYNIS")"
        echo "tests=$(grep '^lynis_tests_done=' "$RAPPORT_LYNIS" | cut -d= -f2)"
        echo "ssh_fail=$(compter '\[fail\]' "$AUDITS/ssh-audit-$etat.txt")"
        echo "ssh_warn=$(compter '\[warn\]' "$AUDITS/ssh-audit-$etat.txt")"
        echo "verifier=$(tail -n 1 "$AUDITS/verifier-$etat.txt" | grep -oE '[0-9]+ / [0-9]+' || true)"
    } > "$AUDITS/mesures-$etat.txt"
}

# mesure <avant|apres> <clé> : valeur enregistrée, « — » si cet état n'a pas été audité
mesure() {
    local f="$AUDITS/mesures-$1.txt"
    if [[ -f $f ]]; then grep "^$2=" "$f" | cut -d= -f2-; else echo "—"; fi
}

ecrire_resume() {
    local ligne
    {
        echo "# Audits Lynis et ssh-audit : avant et après installer.sh"
        echo
        echo "Produit par \`audit.sh\`. « Avant » : VM Debian 13 vierge ; « après » : après"
        echo "\`installer.sh\`. Les deux audits tournent sur la même VM, avec les mêmes outils."
        echo
        echo "| Mesure | Avant | Après |"
        echo "| --- | --- | --- |"
        for ligne in "verifier.sh : tests réussis:verifier" \
                     "Lynis : indice de durcissement (sur 100):indice" \
                     "Lynis : avertissements:avertissements" \
                     "Lynis : suggestions:suggestions" \
                     "Lynis : tests effectués:tests" \
                     "ssh-audit : points « fail »:ssh_fail" \
                     "ssh-audit : points « warn »:ssh_warn" \
                     "Date de l'audit:date"; do
            echo "| ${ligne%:*} | $(mesure avant "${ligne##*:}") | $(mesure apres "${ligne##*:}") |"
        done
        echo
        echo "Outils : Lynis $(dpkg-query -W -f='${Version}' lynis)," \
             "ssh-audit $(dpkg-query -W -f='${Version}' ssh-audit), $(ssh -V 2>&1 | cut -d, -f1)."
        echo
        echo "Détails : \`verifier-<état>.txt\`, \`lynis-<état>.txt\` (sortie complète),"
        echo "\`lynis-<état>-points.txt\` (avertissements et suggestions), \`ssh-audit-<état>.txt\`."
    } > "$AUDITS/resume.md"
}

main() {
    [[ $# -eq 1 && $1 =~ ^(avant|apres)$ ]] || usage
    [[ $EUID -eq 0 ]] || erreur "à lancer en root (sudo $0 $1)"
    install -d "$AUDITS"
    installer_outils
    auditer "$1"
    ecrire_resume
    # Fichiers rendus à l'administrateur qui a lancé sudo : il peut les copier ou les committer
    chown -R "${SUDO_USER:-root}:" "$AUDITS"
    echo
    cat "$AUDITS/resume.md"
}

main "$@"
