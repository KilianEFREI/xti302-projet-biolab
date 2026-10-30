#!/bin/bash
# verifier.sh : verifie que le serveur respecte les exigences du projet
# Il modifie rien (sauf des fichiers de test qui sont supprimes tout de suite).
# Utilisation : sudo ./verifier.sh
# Code de sortie : 0 si tout est OK, 1 sinon

set -u

DOSSIER=$(cd "$(dirname "$0")" && pwd)
CSV="$DOSSIER/comptes.csv"
REUSSIS=0
TOTAL=0

if [ "$(id -u)" -ne 0 ]; then
    echo "Erreur : il faut lancer le script en root (sudo)"
    exit 1
fi

# affiche [OK] ou [KO] selon le code de retour de la derniere commande
resultat() {
    if [ "$1" -eq 0 ]; then
        echo "[OK] $2"
        REUSSIS=$((REUSSIS + 1))
    else
        echo "[KO] $2"
    fi
    TOTAL=$((TOTAL + 1))
}

# premier membre d'un groupe dans le csv (pour faire les tests de droits)
membre() {
    tr -d '\r' < "$CSV" | awk -F';' -v g="$1" '$3 == g {print $1; exit}'
}

# lance une commande en tant qu'un autre utilisateur, sans rien afficher
en_tant_que() {
    sudo -u "$1" bash -c "$2" > /dev/null 2>&1
}

# valeur d'une option de la config ssh effective (sshd -T)
option_ssh() {
    sshd -T -C user="$1",host=localhost,addr=127.0.0.1 2>/dev/null | awk -v o="$2" '$1 == o {print $2}'
}

TECH=$(membre technique)
CHERCHEUR=$(membre chercheurs)
DOCTORANT=$(membre doctorants)
INVITE=$(membre invite)
ADMIN=$(membre admins)

# ---------- C1 : comptes ----------

test_C1_comptes() {
    local erreur=0
    while IFS=';' read -r login nom principal secondaires; do
        [ -z "$login" ] && continue
        if ! id "$login" > /dev/null 2>&1; then
            erreur=1
            continue
        fi
        [ "$(id -gn "$login")" = "$principal" ] || erreur=1
        for g in $(echo "$secondaires" | tr ',' ' '); do
            id -nG "$login" | grep -qw "$g" || erreur=1
        done
    done < <(tr -d '\r' < "$CSV" | tail -n +2)
    resultat $erreur "C1  chaque compte du csv existe avec les bons groupes"
}

test_C1_doublons() {
    [ -z "$(cut -d: -f1 /etc/passwd | sort | uniq -d)" ]
    resultat $? "C1  aucun compte en double"
}

test_C1_invite_nologin() {
    [ "$(getent passwd "$INVITE" | cut -d: -f7)" = "/usr/sbin/nologin" ]
    resultat $? "C1  l'invite $INVITE a pas de shell (nologin)"
}

# ---------- C2 : droits sur /srv ----------

test_C2_technique_ecrit_brutes() {
    en_tant_que "$TECH" "touch /srv/donnees_brutes/.verif && rm /srv/donnees_brutes/.verif"
    resultat $? "C2  technique ($TECH) peut ecrire dans /srv/donnees_brutes"
}

test_C2_chercheur_lit_brutes() {
    en_tant_que "$CHERCHEUR" "ls /srv/donnees_brutes"
    resultat $? "C2  chercheurs ($CHERCHEUR) peut lire /srv/donnees_brutes"
}

test_C2_chercheur_ecrit_pas_brutes() {
    ! en_tant_que "$CHERCHEUR" "touch /srv/donnees_brutes/.verif"
    resultat $? "C2  chercheurs ($CHERCHEUR) peut pas ecrire dans /srv/donnees_brutes"
}

test_C2_technique_pas_analyses() {
    ! en_tant_que "$TECH" "ls /srv/analyses"
    resultat $? "C2  technique ($TECH) peut pas lire /srv/analyses"
}

test_C2_doctorant_ecrit_analyses() {
    en_tant_que "$DOCTORANT" "touch /srv/analyses/.verif && rm /srv/analyses/.verif"
    resultat $? "C2  doctorants ($DOCTORANT) peut ecrire dans /srv/analyses"
}

test_C2_doctorant_ecrit_pas_publications() {
    ! en_tant_que "$DOCTORANT" "touch /srv/publications/.verif"
    resultat $? "C2  doctorants ($DOCTORANT) peut pas ecrire dans /srv/publications"
}

test_C2_invite_lit_publications() {
    en_tant_que "$INVITE" "ls /srv/publications"
    resultat $? "C2  invite ($INVITE) peut lire /srv/publications"
}

test_C2_invite_pas_brutes() {
    ! en_tant_que "$INVITE" "ls /srv/donnees_brutes"
    resultat $? "C2  invite ($INVITE) peut pas lire /srv/donnees_brutes"
}

# ACL par defaut : un fichier cree par un chercheur doit etre modifiable par un doctorant
test_C2_acl_defaut() {
    en_tant_que "$CHERCHEUR" "echo test > /srv/analyses/.verif_acl"
    en_tant_que "$DOCTORANT" "echo ajout >> /srv/analyses/.verif_acl"
    local r=$?
    rm -f /srv/analyses/.verif_acl
    resultat $r "C2  ACL par defaut : un doctorant peut modifier un fichier cree par un chercheur"
}

# ---------- C3 : sudo ----------

test_C3_admins() {
    sudo -l -U "$ADMIN" | grep -q "(ALL : ALL) ALL"
    resultat $? "C3  l'admin $ADMIN a tous les droits sudo"
}

test_C3_support() {
    local regles
    regles=$(sudo -l -U support | grep -E '^\s+\(')
    [ "$(echo "$regles" | wc -l)" -eq 1 ] && echo "$regles" | grep -q "/usr/local/sbin/analyse_logs.sh$"
    resultat $? "C3  le compte support peut lancer que analyse_logs.sh"
}

test_C3_personne_dautre() {
    local erreur=0
    local u
    for u in $(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd); do
        id -nG "$u" | grep -qw admins && continue
        [ "$u" = "support" ] && continue
        sudo -l -U "$u" | grep -q "not allowed" || erreur=1
    done
    [ -z "$(getent group sudo | cut -d: -f4)" ] || erreur=1
    resultat $erreur "C3  aucun autre compte a sudo (groupe sudo vide)"
}

# ---------- C4 : root et dossiers perso ----------

test_C4_root_verrouille() {
    [ "$(passwd -S root | awk '{print $2}')" = "L" ]
    resultat $? "C4  le compte root est verrouille"
}

test_C4_homes() {
    local erreur=0
    local d droits
    for d in /home/*/; do
        droits=$(stat -c %a "$d")
        # les 2 derniers chiffres (groupe et autres) doivent etre a 0
        [ "${droits: -2}" = "00" ] || erreur=1
    done
    resultat $erreur "C4  aucun dossier perso lisible par les autres"
}

# ---------- S1 a S5 : SSH ----------

test_S1_config() {
    [ "$(option_ssh "$ADMIN" passwordauthentication)" = "no" ] && [ "$(option_ssh "$ADMIN" pubkeyauthentication)" = "yes" ]
    resultat $? "S1  config : cle obligatoire, mot de passe desactive"
}

test_S1_connexion_mdp_refusee() {
    ssh -o BatchMode=yes -o PubkeyAuthentication=no -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$ADMIN@127.0.0.1" true 2>&1 | grep -q "Permission denied (publickey)"
    resultat $? "S1  une connexion par mot de passe est refusee"
}

test_S2_root() {
    [ "$(option_ssh root permitrootlogin)" = "no" ]
    resultat $? "S2  connexion root refusee"
}

test_S3_allowgroups() {
    [ "$(option_ssh "$ADMIN" allowgroups)" = "acces_ssh" ]
    resultat $? "S3  seuls les membres de acces_ssh peuvent se connecter"
}

test_S4_essais() {
    [ "$(option_ssh "$ADMIN" maxauthtries)" -le 4 ]
    resultat $? "S4  4 essais d'authentification maximum"
}

test_S4_inactivite() {
    local intervalle nombre
    intervalle=$(option_ssh "$ADMIN" clientaliveinterval)
    nombre=$(option_ssh "$ADMIN" clientalivecountmax)
    [ $((intervalle * nombre)) -le 900 ] && [ "$intervalle" -gt 0 ]
    resultat $? "S4  session coupee au bout de 15 min maximum"
}

test_S4_invite_sftp() {
    [ "$(option_ssh "$INVITE" forcecommand)" = "internal-sftp" ]
    resultat $? "S4  les invites sont limites au SFTP"
}

test_S5_config() {
    [ -f /etc/ssh/sshd_config.d/01-biolab.conf ] && sshd -t
    resultat $? "S5  config dans sshd_config.d et sshd -t valide"
}

# ---------- J1 a J4 : journaux et defense ----------

test_J1_fail2ban_actif() {
    systemctl is-active --quiet fail2ban && fail2ban-client status sshd > /dev/null 2>&1
    resultat $? "J1  fail2ban est actif et surveille SSH"
}

test_J1_config() {
    local essais action
    essais=$(fail2ban-client get sshd maxretry 2>/dev/null)
    action=$(fail2ban-client get sshd actions 2>/dev/null)
    [ -n "$essais" ] && [ "$essais" -le 5 ] && echo "$action" | grep -q nftables
    resultat $? "J1  fail2ban bannit apres 5 echecs max, avec nftables"
}

test_J2_politique_drop() {
    nft list chain inet filter input 2>/dev/null | grep -q "policy drop"
    resultat $? "J2  politique par defaut du pare-feu : drop"
}

test_J2_ssh_autorise() {
    nft list chain inet filter input 2>/dev/null | grep -q "tcp dport 22 accept"         && nft list chain inet filter input | grep -q "ct state established,related accept"
    resultat $? "J2  SSH et connexions etablies autorises"
}

test_J2_au_demarrage() {
    systemctl is-enabled --quiet nftables && cmp -s "$DOSSIER/config/nftables.conf" /etc/nftables.conf
    resultat $? "J2  regles chargees au demarrage (service nftables active)"
}

test_J3_persistant() {
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -q "^Storage=persistent"         && [ -d /var/log/journal ]
    resultat $? "J3  journal persistant (Storage=persistent, /var/log/journal)"
}

test_J4_installe() {
    local f=/usr/local/sbin/analyse_logs.sh
    # le script doit appartenir a root et etre modifiable que par root
    [ -x "$f" ] && [ "$(stat -c %U "$f")" = "root" ] && [ "$(stat -c %a "$f")" = "755" ]
    resultat $? "J4  analyse_logs.sh installe, appartient a root, modifiable que par root"
}

# on fabrique un faux log avec 3 connexions ratees de la meme IP
test_J4_code_retour() {
    local log r1 r2
    log=$(mktemp)
    for p in 1 2 3; do
        echo "sshd-session[10$p]: Connection closed by invalid user test 203.0.113.9 port 4000$p [preauth]" >> "$log"
    done
    /usr/local/sbin/analyse_logs.sh -f "$log" -s 3 > /dev/null; r1=$?
    /usr/local/sbin/analyse_logs.sh -f "$log" -s 10 > /dev/null; r2=$?
    rm -f "$log"
    [ $r1 -eq 2 ] && [ $r2 -eq 0 ]
    resultat $? "J4  analyse_logs.sh renvoie 2 au-dessus du seuil et 0 en dessous"
}

# ---------- B1 a B4 : sauvegarde ----------

SAUV=/sauvegardes

# derniere et avant-derniere version
derniere() { ls -1d "$SAUV"/20*/ 2>/dev/null | tail -n 1; }
avant_derniere() { ls -1d "$SAUV"/20*/ 2>/dev/null | tail -n 2 | head -n 1; }

test_B1_disque() {
    # monte, sur un autre disque que le systeme, et monte par UUID dans fstab
    mountpoint -q "$SAUV" \
        && [ "$(findmnt -no SOURCE "$SAUV")" != "$(findmnt -no SOURCE /)" ] \
        && grep -qE "^UUID=[^ ]+[[:space:]]+$SAUV[[:space:]]" /etc/fstab
    resultat $? "B1  $SAUV est un disque a part, monte par UUID"
}

test_B1_version() {
    local d
    d=$(derniere)
    [ -n "$d" ] && [ -d "$d/srv" ] && [ -d "$d/etc" ]
    resultat $? "B1  une version datee contient /srv et /etc"
}

test_B1_acl() {
    local d
    d=$(derniere)
    [ -n "$d" ] && [ "$(getfacl -p --omit-header /srv/analyses)" = "$(getfacl -p --omit-header "$d/srv/analyses")" ]
    resultat $? "B1  les ACL sont conservees dans la sauvegarde"
}

# un fichier qui a pas change est le meme fichier (meme inode) dans les 2 dernieres versions
test_B1_incremental() {
    local a b
    a=$(avant_derniere)
    b=$(derniere)
    [ -n "$a" ] && [ "$a" != "$b" ] && [ "$(stat -c %i "$a/etc/hostname")" = "$(stat -c %i "$b/etc/hostname")" ]
    resultat $? "B1  sauvegarde incrementale (fichier inchange = lien dur)"
}

test_B1_rotation() {
    local nb
    nb=$(ls -1d "$SAUV"/20*/ 2>/dev/null | wc -l)
    [ "$nb" -ge 1 ] && [ "$nb" -le 7 ] && grep -q "^GARDER=7" /usr/local/sbin/sauvegarde.sh
    resultat $? "B1  7 versions gardees au maximum ($nb actuellement)"
}

test_B2_planifiee() {
    grep -q "/usr/local/sbin/sauvegarde.sh" /etc/cron.d/sauvegarde 2>/dev/null && systemctl is-active --quiet cron
    resultat $? "B2  sauvegarde planifiee avec cron"
}

test_B2_journal() {
    grep -q "terminee" /var/log/sauvegarde.log 2>/dev/null
    resultat $? "B2  chaque sauvegarde est journalisee (/var/log/sauvegarde.log)"
}

test_B3_droits() {
    [ "$(stat -c '%U %a' "$SAUV")" = "root 700" ] && ! en_tant_que "$TECH" "ls $SAUV"
    resultat $? "B3  $SAUV accessible qu'en root (admins via sudo)"
}

# on restaure un fichier de la derniere version dans un dossier temporaire
test_B4_restauration() {
    local d tmp r
    d=$(derniere)
    tmp=$(mktemp -d)
    rsync -aAX "$d/etc/hostname" "$tmp/" 2> /dev/null && cmp -s "$tmp/hostname" "$d/etc/hostname"
    r=$?
    rm -rf "$tmp"
    [ -n "$d" ] && [ $r -eq 0 ]
    resultat $? "B4  restauration d'un fichier depuis une version"
}

# ---------- D1 a D3 : systeme ----------

test_D1_installe() {
    dpkg -s unattended-upgrades 2>/dev/null | grep -q "Status: install ok installed"
    resultat $? "D1  unattended-upgrades est installe"
}

test_D1_active() {
    apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"' \
        && systemctl is-enabled --quiet apt-daily-upgrade.timer
    resultat $? "D1  mises a jour de securite automatiques activees"
}

# tout ce qui ecoute hors de la machine doit etre SSH (22)
# ou le client DHCP (68 et 546 en udp, il recoit les reponses du serveur DHCP)
test_D2_ecoutes() {
    local autres
    autres=$(ss -Htuln | awk '{print $5}' | grep -vE ':(22|68|546)$' | grep -vE '^(127\.|\[::1\])')
    [ -z "$autres" ]
    resultat $? "D2  rien d'autre que SSH (et le client DHCP) n'ecoute sur le reseau"
}

test_D3_modifiable_par_tous() {
    local f
    f=$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /var/tmp \) -prune \
        -o -type f -perm -0002 -print 2>/dev/null)
    [ -z "$f" ]
    resultat $? "D3  aucun fichier modifiable par tous hors dossiers temporaires"
}

test_D3_suid() {
    local inconnus
    inconnus=$(comm -23 <(find / -xdev -type f -perm -4000 2>/dev/null | sort) <(sort "$DOSSIER/config/suid_attendus.txt"))
    [ -z "$inconnus" ]
    resultat $? "D3  tous les fichiers SUID sont dans la liste connue"
}

# ---------- lancement de tous les tests ----------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    $t
done

echo "--- $REUSSIS / $TOTAL tests reussis"

if [ "$REUSSIS" -eq "$TOTAL" ]; then
    exit 0
else
    exit 1
fi
