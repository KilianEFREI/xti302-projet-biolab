#!/bin/bash
# creer_comptes.sh : cree les groupes, les comptes, les dossiers de /srv et les ACL
# a partir de comptes.csv. On peut le relancer sans probleme (idempotent).
# Utilisation : sudo ./creer_comptes.sh

set -u

DOSSIER=$(cd "$(dirname "$0")" && pwd)
CSV="$DOSSIER/comptes.csv"
CLES="$DOSSIER/config/keys"

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : il faut lancer le script en root (sudo)"
    exit 1
fi

if ! command -v setfacl > /dev/null; then
    echo "Erreur : setfacl introuvable (sudo apt install acl)"
    exit 1
fi

# cree le groupe seulement s'il existe pas deja
creer_groupe() {
    if ! getent group "$1" > /dev/null; then
        groupadd "$1"
        echo "groupe $1 cree"
    fi
}

# ---------- comptes ----------
# tr enleve les \r au cas ou le csv a ete enregistre sous Windows
# tail -n +2 saute la ligne d'en-tete
tr -d '\r' < "$CSV" | tail -n +2 | while IFS=';' read -r login nom principal secondaires; do
    [ -z "$login" ] && continue

    creer_groupe "$principal"
    for g in $(echo "$secondaires" | tr ',' ' '); do
        creer_groupe "$g"
    done

    # les invites ont pas de shell, ils font que du SFTP
    if [ "$principal" = "invite" ]; then
        shell=/usr/sbin/nologin
    else
        shell=/bin/bash
    fi

    if ! id "$login" > /dev/null 2>&1; then
        useradd -m -g "$principal" -s "$shell" -c "$nom" "$login"
        echo "compte $login cree"
    fi
    # usermod a chaque fois pour remettre les bons groupes si le csv a change
    usermod -g "$principal" -G "$secondaires" -s "$shell" -c "$nom" "$login"

    # dossier perso lisible que par son proprietaire
    maison=$(getent passwd "$login" | cut -d: -f6)
    chmod 700 "$maison"

    # cle publique (seulement pour les comptes qui ont une cle dans le depot)
    if [ -f "$CLES/$login.pub" ]; then
        mkdir -p "$maison/.ssh"
        cp "$CLES/$login.pub" "$maison/.ssh/authorized_keys"
        chown -R "$login:$principal" "$maison/.ssh"
        chmod 700 "$maison/.ssh"
        chmod 600 "$maison/.ssh/authorized_keys"
    fi
done

# ---------- dossiers de /srv ----------
# donne les droits a un groupe sur un dossier, et aussi en ACL par defaut
# pour que les fichiers crees plus tard aient les memes droits
droits() {
    setfacl -m "g:$2:$3" "$1"
    setfacl -d -m "g:$2:$3" "$1"
}

for d in /srv/donnees_brutes /srv/analyses /srv/publications; do
    mkdir -p "$d"
    chown root:root "$d"
    chmod 700 "$d"
    # on enleve les anciennes ACL pour repartir propre a chaque lancement
    setfacl -b "$d"
done

droits /srv/donnees_brutes technique rwx
droits /srv/donnees_brutes chercheurs r-x
droits /srv/donnees_brutes doctorants r-x

droits /srv/analyses chercheurs rwx
droits /srv/analyses doctorants rwx

droits /srv/publications chercheurs rwx
droits /srv/publications doctorants r-x
droits /srv/publications invite r-x

echo "creer_comptes.sh termine"
