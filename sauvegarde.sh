#!/usr/bin/env bash
# sauvegarde.sh — sauvegarde incrémentale versionnée de /srv et /etc (B1)
# Chaque exécution crée /sauvegardes/AAAA-MM-JJ_HHMMSS ; les fichiers inchangés
# sont des liens physiques vers la version précédente (--link-dest).
# Usage : sudo sauvegarde.sh     (lancé chaque nuit par sauvegarde.timer)
set -euo pipefail

readonly DEST=/sauvegardes
readonly SOURCES=(/srv /etc)
readonly A_GARDER=7
DATE=$(date +%Y-%m-%d_%H%M%S)
readonly DATE

erreur() { echo "ERREUR : $*" >&2; exit 1; }

verifier() {
    [[ $EUID -eq 0 ]] || erreur "à lancer en root"
    # Disque non monté : on écrirait sur le disque système sans s'en rendre compte
    mountpoint -q "$DEST" || erreur "$DEST n'est pas monté : sauvegarde annulée"
}

versions() {   # versions complètes, de la plus ancienne à la plus récente
    find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' ! -name '*.encours' | sort
}

sauvegarder() {
    local precedente cible="$DEST/$DATE"
    precedente=$(versions | tail -n 1)
    rm -rf "$DEST"/*.encours                  # restes d'une exécution interrompue
    local opts=(-aAXH --numeric-ids)
    if [[ -n $precedente ]]; then
        opts+=(--link-dest="$precedente")
    fi
    rsync "${opts[@]}" "${SOURCES[@]}" "$cible.encours/"
    mv "$cible.encours" "$cible"             # la version n'est « valide » qu'une fois complète
    echo "version créée : $cible (base : ${precedente:-aucune})"
}

rotation() {
    local liste v
    mapfile -t liste < <(versions)
    if (( ${#liste[@]} > A_GARDER )); then
        for v in "${liste[@]:0:${#liste[@]}-A_GARDER}"; do
            rm -rf -- "$v"
            echo "version supprimée : $v"
        done
    fi
}

main() { verifier; sauvegarder; rotation; }
main "$@"
