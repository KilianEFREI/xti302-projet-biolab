#!/bin/bash
# analyse_logs.sh : rapport des connexions SSH
#   - connexions ratees par IP
#   - comptes vises
#   - connexions reussies
# Utilisation : sudo analyse_logs.sh [-s seuil] [-p periode] [-f fichier]
#   -s seuil   : nombre de connexions ratees a partir duquel une IP est en alerte (defaut 5)
#   -p periode : periode analysee, format journalctl (defaut "24 hours ago")
#   -f fichier : analyser un fichier de log au lieu du journal
# Code de sortie : 0 = rien d'anormal, 1 = erreur, 2 = au moins une IP depasse le seuil

SEUIL=5
PERIODE="24 hours ago"
FICHIER=""

while getopts "s:p:f:" opt; do
    case $opt in
        s) SEUIL=$OPTARG ;;
        p) PERIODE=$OPTARG ;;
        f) FICHIER=$OPTARG ;;
        *) echo "Utilisation : $0 [-s seuil] [-p periode] [-f fichier]"; exit 1 ;;
    esac
done

# le seuil doit etre un nombre (le script tourne en root via sudo, on verifie ce qu'on recoit)
if ! [[ "$SEUIL" =~ ^[0-9]+$ ]]; then
    echo "Erreur : le seuil doit etre un nombre"
    exit 1
fi

if [ -n "$FICHIER" ]; then
    if [ ! -r "$FICHIER" ]; then
        echo "Erreur : impossible de lire $FICHIER"
        exit 1
    fi
    LOGS=$(cat "$FICHIER")
    SOURCE="fichier $FICHIER"
else
    # -u ssh marche pour Debian 12 (sshd) et Debian 13 (sshd-session)
    LOGS=$(journalctl -u ssh --since "$PERIODE" --no-pager 2>/dev/null)
    SOURCE="journal, depuis $PERIODE"
fi

# une connexion ratee = une connexion fermee avant d'etre authentifiee.
# sshd ecrit une de ces lignes a la fin de chaque connexion ratee :
#   Connection closed by invalid user admin 203.0.113.45 port 41022 [preauth]
#   Connection reset by invalid user faux 10.0.2.2 port 12434 [preauth]
#   Disconnected from authenticating user root 203.0.113.45 port 41078 [preauth]
#   Disconnecting authenticating user root 203.0.113.45 port 41070: Too many ...
# on garde "compte IP" pour chaque ligne
ECHECS=$(echo "$LOGS" \
    | grep -E "(Connection (closed|reset) by|Disconnected from|Disconnecting) (authenticating|invalid) user" \
    | sed -E 's/.* (authenticating|invalid) user ([^ ]+) ([0-9a-fA-F.:]+) port.*/\2 \3/')

# connexions reussies : "Accepted publickey for knivet from 192.168.56.1 port ..."
REUSSIES=$(echo "$LOGS" | grep "Accepted " \
    | sed -E 's/.*Accepted ([a-z-]+) for ([^ ]+) from ([^ ]+) port.*/\2 depuis \3 (\1)/')

echo "=== Rapport SSH - $(hostname) - $(date '+%d/%m/%Y %H:%M') ==="
echo "Source : $SOURCE"
echo "Seuil d'alerte : $SEUIL connexions ratees par IP"
echo

echo "--- Connexions ratees par IP"
if [ -z "$ECHECS" ]; then
    echo "aucune"
else
    echo "$ECHECS" | awk '{print $2}' | sort | uniq -c | sort -rn
fi
echo

echo "--- Comptes vises"
if [ -z "$ECHECS" ]; then
    echo "aucun"
else
    echo "$ECHECS" | awk '{print $1}' | sort | uniq -c | sort -rn
fi
echo

echo "--- Connexions reussies"
if [ -z "$REUSSIES" ]; then
    echo "aucune"
else
    echo "$REUSSIES" | sort | uniq -c | sort -rn
fi
echo

# IP qui depassent le seuil
ALERTES=""
if [ -n "$ECHECS" ]; then
    ALERTES=$(echo "$ECHECS" | awk '{print $2}' | sort | uniq -c | awk -v s="$SEUIL" '$1 >= s {print $2 " (" $1 " connexions ratees)"}')
fi

if [ -n "$ALERTES" ]; then
    echo "!!! ALERTE : IP au-dessus du seuil"
    echo "$ALERTES"
    exit 2
fi

echo "Aucune IP au-dessus du seuil."
exit 0
