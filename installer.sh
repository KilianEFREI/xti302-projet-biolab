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
apt-get install -y -q acl sudo nftables fail2ban python3-systemd rsync cron unattended-upgrades

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

echo "== journal persistant (J3)"
install -d -m 755 /etc/systemd/journald.conf.d
install -m 644 config/journald.conf.d/10-persistent.conf /etc/systemd/journald.conf.d/10-persistent.conf
systemctl restart systemd-journald

echo "== pare-feu nftables (J2)"
# nft -c verifie le fichier sans l'appliquer
nft -c -f config/nftables.conf || exit 1
install -m 644 -o root -g root config/nftables.conf /etc/nftables.conf
# enable : les regles sont rechargees a chaque demarrage
systemctl enable nftables
systemctl restart nftables

echo "== fail2ban (J1)"
install -m 644 config/fail2ban/jail.d/sshd-biolab.conf /etc/fail2ban/jail.d/sshd-biolab.conf
systemctl enable fail2ban
# restart apres nftables pour que fail2ban recree sa table de ban
systemctl restart fail2ban

echo "== analyse_logs.sh (J4)"
# appartient a root et modifiable que par root : sinon support pourrait
# changer le script et faire n'importe quoi en root avec sudo
install -m 755 -o root -g root analyse_logs.sh /usr/local/sbin/analyse_logs.sh

echo "== mises a jour automatiques (D1)"
install -m 644 config/apt/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable apt-daily.timer apt-daily-upgrade.timer

echo "== disque de sauvegarde (B1)"
# on prepare le disque seulement s'il est pas deja dans fstab :
# relancer installer.sh doit jamais reformater le disque et perdre les sauvegardes
if ! grep -qE "[[:space:]]/sauvegardes[[:space:]]" /etc/fstab; then
    # on cherche un disque vide : pas de partition, pas de systeme de fichiers, moins de 10 Go
    # (les noms sda/sdb peuvent s'inverser d'un demarrage a l'autre, on se fie pas au nom)
    DISQUE=""
    for d in $(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}'); do
        if [ "$(lsblk -no NAME "$d" | wc -l)" -eq 1 ] \
            && [ -z "$(lsblk -no FSTYPE "$d" | tr -d ' \n')" ] \
            && [ "$(lsblk -dnbo SIZE "$d")" -lt 10737418240 ]; then
            DISQUE=$d
        fi
    done

    if [ -z "$DISQUE" ]; then
        echo "ATTENTION : aucun disque vide trouve pour les sauvegardes"
    else
        echo "disque de sauvegarde : $DISQUE"
        echo 'type=linux' | sfdisk -q --label gpt "$DISQUE"
        udevadm settle
        PARTITION=$(lsblk -lnpo NAME "$DISQUE" | sed -n 2p)
        mkfs.ext4 -q -L sauvegardes "$PARTITION"
        mkdir -p /sauvegardes
        # montage par UUID et nofail : la VM demarre meme si le disque manque
        echo "UUID=$(blkid -s UUID -o value "$PARTITION") /sauvegardes ext4 defaults,nofail 0 2" >> /etc/fstab
        systemctl daemon-reload
    fi
fi
mountpoint -q /sauvegardes || mount /sauvegardes

echo "== sauvegarde (B1 a B3)"
install -m 755 -o root -g root sauvegarde.sh /usr/local/sbin/sauvegarde.sh
install -m 644 -o root -g root config/cron.d/sauvegarde /etc/cron.d/sauvegarde
if mountpoint -q /sauvegardes; then
    chown root:root /sauvegardes
    chmod 700 /sauvegardes
    # s'il y a encore aucune version, on en fait 2 tout de suite :
    # la premiere copie tout, la deuxieme montre que l'incremental marche
    if [ -z "$(ls -d /sauvegardes/20*/ 2>/dev/null)" ]; then
        /usr/local/sbin/sauvegarde.sh
        sleep 1
        /usr/local/sbin/sauvegarde.sh
    fi
else
    echo "ATTENTION : /sauvegardes est pas monte, pas de sauvegarde"
fi

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
