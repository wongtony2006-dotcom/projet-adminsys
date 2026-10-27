#!/usr/bin/env bash
# analyse_logs.sh — rapport des connexions SSH (exigence J4)
# Usage : sudo analyse_logs.sh [-s SEUIL] [-p today|24h|7d]
#   -s SEUIL   échecs par IP à partir desquels on alerte (défaut : 10)
#   -p PERIODE fenêtre analysée (défaut : 24h)
# Codes de sortie : 0 = rien d'anormal, 1 = seuil atteint, 2 = mauvaise utilisation
# Lancé en root via sudo par le compte support : appartient à root, mode 0755.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin   # PATH maîtrisé : pas de commande piégée

SEUIL=10
PERIODE=24h

usage() { echo "Usage : $0 [-s SEUIL] [-p today|24h|7d]" >&2; exit 2; }

lire_options() {
    local opt
    while getopts ":s:p:h" opt; do
        case $opt in
            s) [[ $OPTARG =~ ^[0-9]+$ ]] || usage; SEUIL=$OPTARG ;;
            p) case $OPTARG in today|24h|7d) PERIODE=$OPTARG ;; *) usage ;; esac ;;
            *) usage ;;
        esac
    done
    shift $((OPTIND - 1))
    [[ $# -eq 0 ]] || usage            # aucun argument libre accepté
}

depuis() {   # période -> argument de journalctl --since
    case $PERIODE in
        today) echo "today" ;;
        24h)   echo "24 hours ago" ;;
        7d)    echo "7 days ago" ;;
    esac
}

lire_journal() {
    # --no-pager : en root, un pager (less) permettrait d'ouvrir un shell avec !sh
    journalctl -u ssh --since "$(depuis)" --no-pager -o cat
}

# Une ligne « IP COMPTE » par tentative échouée
echecs() {
    sed -nE \
        -e 's/.*Invalid user (\S*) from (\S+) port.*/\2 \1/p' \
        -e 's/.*User (\S+) from (\S+) not allowed because.*/\2 \1/p' \
        -e 's/.*Connection (closed|reset) by authenticating user (\S+) (\S+) port.*/\3 \2/p' \
        -e 's/.*Failed password for (invalid user )?(\S+) from (\S+) port.*/\3 \2/p'
}

# Une ligne « IP COMPTE (méthode) » par connexion réussie
reussites() {
    sed -nE 's/.*Accepted (\S+) for (\S+) from (\S+) port.*/\3 \2 (\1)/p'
}

main() {
    lire_options "$@"
    [[ $EUID -eq 0 ]] || { echo "À lancer en root (sudo)" >&2; exit 2; }

    local journal liste_echecs max
    journal=$(lire_journal)
    liste_echecs=$(echecs <<< "$journal")

    echo "=== Rapport SSH — depuis : $(depuis) — seuil : $SEUIL échecs par IP ==="
    echo "--- Échecs par adresse IP ---"
    awk 'NF {print $1}' <<< "$liste_echecs" | sort | uniq -c | sort -rn
    echo "--- Comptes visés ---"
    awk 'NF {print $2}' <<< "$liste_echecs" | sort | uniq -c | sort -rn
    echo "--- Connexions réussies ---"
    reussites <<< "$journal" | sort | uniq -c | sort -rn

    max=$(awk 'NF {print $1}' <<< "$liste_echecs" | sort | uniq -c | sort -rn | awk 'NR == 1 {print $1}')
    max=${max:-0}
    if (( max >= SEUIL )); then
        echo "ALERTE : une adresse IP totalise $max échecs (seuil : $SEUIL)"
        exit 1
    fi
    echo "OK : maximum $max échecs pour une même IP (seuil : $SEUIL)"
}

main "$@"
