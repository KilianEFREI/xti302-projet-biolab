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
