#!/bin/bash
# installer.sh : installe toute la configuration du serveur BioLab
# Utilisation : sudo ./installer.sh   (depuis le dossier du depot)

set -u

DOSSIER=$(cd "$(dirname "$0")" && pwd)
cd "$DOSSIER"

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : il faut lancer le script en root (sudo)"
    exit 1
fi

echo "== paquets"
apt-get update -q
apt-get install -y -q acl sudo

echo "== comptes, groupes et /srv"
./creer_comptes.sh || exit 1

# C4 : aucun dossier perso lisible par les autres (debian compris)
chmod 700 /home/*

echo "== sudo"
# on verifie la syntaxe avant de copier, sinon on peut casser sudo
visudo -cf config/sudoers.d/biolab || exit 1
install -m 440 -o root -g root config/sudoers.d/biolab /etc/sudoers.d/biolab

# les admins ont pas de mot de passe a la creation, il en faut un pour sudo
gid_admins=$(getent group admins | cut -d: -f3)
for u in $(getent passwd | awk -F: -v g="$gid_admins" '$4 == g {print $1}'); do
    if [ "$(passwd -S "$u" | awk '{print $2}')" != "P" ]; then
        echo "mot de passe sudo pour $u :"
        passwd "$u"
    fi
done

echo "== SSH"
install -m 644 -o root -g root config/ssh/sshd_config.d/01-biolab.conf /etc/ssh/sshd_config.d/01-biolab.conf
# S5 : on teste la config avant de redemarrer
if ! sshd -t; then
    echo "Erreur dans la config SSH, on l'enleve"
    rm /etc/ssh/sshd_config.d/01-biolab.conf
    exit 1
fi
systemctl restart ssh

echo "== root et compte debian"
# C4 : root verrouille
passwd -l root
# le compte debian de l'image perd sudo et son mot de passe
if id debian > /dev/null 2>&1; then
    if id -nG debian | grep -qw sudo; then
        gpasswd -d debian sudo
    fi
    passwd -l debian
fi

echo "installer.sh termine"
