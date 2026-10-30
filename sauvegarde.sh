#!/bin/bash
# sauvegarde.sh : sauvegarde versionnee de /srv et /etc sur le 2e disque (B1)
# Chaque lancement cree un dossier date dans /sauvegardes, par exemple
# /sauvegardes/2026-10-30_020000/srv et /sauvegardes/2026-10-30_020000/etc
# Les fichiers qui ont pas change depuis la version d'avant sont pas recopies :
# rsync fait un lien dur vers la version d'avant (--link-dest).
# Utilisation : sudo sauvegarde.sh

DEST=/sauvegardes
GARDER=7
JOURNAL=/var/log/sauvegarde.log
SOURCES="/srv /etc"

# ecrit dans le journal avec la date, et a l'ecran
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$JOURNAL"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : il faut lancer le script en root (sudo)"
    exit 1
fi

# si le disque est pas monte on ecrirait sur le disque systeme, donc on arrete
if ! mountpoint -q "$DEST"; then
    log "ERREUR : $DEST n'est pas monte, sauvegarde annulee"
    exit 1
fi

# B3 : que root (les admins passent par sudo)
chown root:root "$DEST"
chmod 700 "$DEST"

VERSION=$(date '+%Y-%m-%d_%H%M%S')
# derniere version terminee (les noms commencent par l'annee donc ls les trie dans l'ordre)
PRECEDENTE=$(ls -1d "$DEST"/20*/ 2>/dev/null | tail -n 1)
# on copie d'abord dans un dossier "en_cours_" : si ca plante on a pas une version a moitie faite
TEMP="$DEST/en_cours_$VERSION"

log "debut de la sauvegarde $VERSION"

# -a : garde droits, proprietaires, dates, liens
# -A : garde les ACL
# -X : garde les attributs etendus
# -H : garde les liens durs
if [ -n "$PRECEDENTE" ]; then
    STATS=$(rsync -aAXH --stats --link-dest="$PRECEDENTE" $SOURCES "$TEMP/" 2>> "$JOURNAL")
else
    STATS=$(rsync -aAXH --stats $SOURCES "$TEMP/" 2>> "$JOURNAL")
fi
CODE=$?

if [ $CODE -ne 0 ]; then
    log "ERREUR : rsync a echoue (code $CODE), version $VERSION abandonnee"
    rm -rf "$TEMP"
    exit 1
fi

mv "$TEMP" "$DEST/$VERSION"
COPIES=$(echo "$STATS" | awk -F: '/Number of regular files transferred/ {gsub(/[ ,]/, "", $2); print $2}')
log "sauvegarde $VERSION terminee : $COPIES fichier(s) copie(s), le reste en lien dur"

# on garde les $GARDER dernieres versions, on supprime les plus vieilles
ls -1d "$DEST"/20*/ | head -n -"$GARDER" | while read -r ancienne; do
    rm -rf "$ancienne"
    log "ancienne version supprimee : $(basename "$ancienne")"
done

exit 0
