# Dossier - Durcissement du serveur BioLab

Kilian NIVET et Ethan PICOLO - B2 Cyber - XTI302-CYB - contexte C (BioLab)

On s'est servi du guide ANSSI-BP-028 (Recommandations de configuration d'un système GNU/Linux), du guide ANSSI sur OpenSSH et des pages de manuel.

## 1. Tableau de conformité

| Exigence | Ce qu'on a fait | Test dans verifier.sh | ANSSI |
|---|---|---|---|
| C1 | creer_comptes.sh lit comptes.csv et crée les groupes et les comptes. Si un compte existe déjà il le met juste à jour avec usermod, donc pas de doublon si on le relance. 2 admins nominatifs : knivet et epicolo. | test_C1_comptes, test_C1_doublons, test_C1_invite_nologin | R33 |
| C2 | Dossiers de /srv en 700 root, puis ACL pour chaque groupe + ACL par défaut pour les nouveaux fichiers. | 8 tests test_C2_* (ce qui doit marcher et ce qui doit être refusé) + test_C2_acl_defaut | R50 |
| C3 | Fichier /etc/sudoers.d/biolab : le groupe admins a tous les droits, support peut lancer seulement analyse_logs.sh. Le compte debian est retiré du groupe sudo. Le fichier est vérifié avec visudo -c avant d'être copié. | test_C3_admins, test_C3_support, test_C3_personne_dautre | R38, R39, R43 |
| C4 | Root verrouillé (passwd -l root), dossiers perso en 700. | test_C4_root_verrouille, test_C4_homes | R33, R50 |
| S1 | PasswordAuthentication no, KbdInteractiveAuthentication no, PubkeyAuthentication yes | test_S1_config, test_S1_connexion_mdp_refusee | guide SSH |
| S2 | PermitRootLogin no | test_S2_root | guide SSH |
| S3 | AllowGroups acces_ssh | test_S3_allowgroups | guide SSH |
| S4 | MaxAuthTries 3, ChannelTimeout session=15m, ClientAliveInterval 300 et ClientAliveCountMax 3. Les invités ont ForceCommand internal-sftp. | test_S4_essais, test_S4_inactivite, test_S4_invite_sftp | guide SSH, R32 |
| S5 | Config dans sshd_config.d/01-biolab.conf, testée avec sshd -t avant de redémarrer SSH. | test_S5_config | - |
| J1 | fail2ban sur SSH : 5 échecs en 10 min = IP bannie 30 min (avec nftables). | test_J1_fail2ban_actif, test_J1_config | R79 |
| J2 | nftables : tout est refusé en entrée (policy drop) sauf lo, les connexions déjà établies et le port 22. Le service est activé au démarrage. | test_J2_politique_drop, test_J2_ssh_autorise, test_J2_au_demarrage | R80 |
| J3 | Storage=persistent dans journald.conf.d | test_J3_persistant | R71 |
| J4 | analyse_logs.sh : échecs par IP, comptes visés, connexions réussies. Seuil de 5 par défaut, code 2 s'il est dépassé. | test_J4_installe, test_J4_code_retour | R71 |
| B1 | sauvegarde.sh : rsync vers /sauvegardes/date, avec --link-dest pour ne pas recopier ce qui n'a pas changé. On garde 7 versions. | test_B1_disque, test_B1_version, test_B1_acl, test_B1_incremental, test_B1_rotation | - |
| B2 | cron tous les jours à 2h, journal dans /var/log/sauvegarde.log | test_B2_planifiee, test_B2_journal | - |
| B3 | /sauvegardes en 700 root | test_B3_droits | R50 |
| B4 | Restauration testée (partie 4) | test_B4_restauration | - |
| D1 | unattended-upgrades installé et activé | test_D1_installe, test_D1_active | R61 |
| D2 | Seul SSH écoute sur le réseau (voir 2.6) | test_D2_ecoutes | R62, R80 |
| D3 | Pas de fichier modifiable par tous, liste des SUID dans config/suid_attendus.txt (voir 2.7) | test_D3_modifiable_par_tous, test_D3_suid | R53, R54, R56, R57 |

Les numéros R sont ceux du guide ANSSI-BP-028.

Résultat sur la VM, après une installation depuis le snapshot vierge : 47 / 47 tests réussis, code de sortie 0.

## 2. Choix techniques

### 2.1 Comptes et droits

- On a utilisé des ACL parce qu'un dossier n'a qu'un seul groupe propriétaire. Par exemple /srv/publications doit être en écriture pour les chercheurs et en lecture pour les doctorants et les invités, ce n'est pas possible avec un seul groupe.
- Les ACL par défaut servent pour les fichiers créés plus tard. Sans elles, un fichier créé par un chercheur dans /srv/analyses ne serait pas modifiable par les doctorants.
- Les dossiers de /srv sont en 700 root : au départ personne n'a accès, et on ouvre seulement ce qui est demandé avec les ACL.
- À chaque lancement, creer_comptes.sh enlève les anciennes ACL (setfacl -b) avant de remettre les bonnes, pour ne pas garder d'anciens droits si on change le tableau.
- Les admins se connectent avec leur clé mais sudo leur demande quand même un mot de passe. Si quelqu'un vole la clé d'un admin, il n'a pas directement root.
- Le compte support n'a pas de mot de passe et peut lancer un seul script en root. Ce script appartient à root et support ne peut pas le modifier, sinon il pourrait mettre n'importe quelle commande dedans et la lancer en root.

### 2.2 SSH

- Le fichier s'appelle 01-biolab.conf parce que sshd garde la première valeur qu'il lit. Avec 01 il est lu en premier.
- MaxAuthTries 3 : avec une clé on se connecte du premier coup, 3 essais c'est suffisant (le sujet demande 4 maximum).
- ChannelTimeout session=15m ferme une session qui n'a rien fait pendant 15 minutes. ClientAliveInterval 300 et ClientAliveCountMax 3 coupent aussi un client qui ne répond plus.
- Pour les invités, ForceCommand internal-sftp oblige à utiliser SFTP. Ça marche même avec le shell nologin parce que le SFTP est intégré à sshd. On a aussi mis PermitTTY no et AllowTcpForwarding no pour qu'ils n'aient pas de terminal ni de tunnel.

### 2.3 Pare-feu et fail2ban

- On bloque tout par défaut et on autorise seulement SSH. Comme ça si un service est installé par erreur, il n'est pas accessible.
- La règle "established,related" laisse passer les réponses quand c'est le serveur qui ouvre la connexion (apt, DNS).
- Dans nftables.conf on n'a pas mis "flush ruleset" mais on supprime seulement notre table. Sinon, recharger le pare-feu effaçait aussi la table de fail2ban avec les IP bannies.
- fail2ban : 5 échecs en 10 minutes. Une vraie personne se trompe 1 ou 2 fois, pas 5. Un ban de 30 minutes ralentit beaucoup une attaque sans bloquer trop longtemps quelqu'un qui s'est trompé.
- On utilise le backend systemd car sur Debian 13 minimale il n'y a pas de fichier /var/log/auth.log, les logs SSH sont dans le journal.

### 2.4 analyse_logs.sh

- Le script lit `journalctl -u ssh`, ça marche que le processus s'appelle sshd (Debian 12) ou sshd-session (Debian 13).
- Une connexion ratée, c'est une connexion fermée avant d'être authentifiée (lignes "Connection closed by", "Connection reset by", "Disconnected from"...). Avec les clés il n'y a plus de lignes "Failed password", donc on ne pouvait pas compter seulement celles-là. Au début on avait oublié "Connection reset by", on l'a vu en faisant un vrai test d'attaque.
- Le seuil est de 5, comme fail2ban.
- Comme le script est lancé en root avec sudo, on vérifie que le seuil est bien un nombre et on utilise --no-pager. Si journalctl ouvrait less en root, on pourrait lancer un shell root depuis less (c'est dans GTFOBins).

### 2.5 Sauvegarde

- Chaque sauvegarde est dans un dossier daté. Avec --link-dest, les fichiers qui n'ont pas changé ne sont pas recopiés, rsync fait un lien dur vers la version d'avant. Sur la VM, après la première sauvegarde, les suivantes ont copié 0 fichier.
- On fait des versions et pas une simple copie miroir : si un fichier est supprimé ou chiffré par un rançongiciel, un miroir recopierait le problème. Avec les versions on peut revenir en arrière.
- Les options -A et -X gardent les ACL, sinon un fichier restauré aurait de mauvais droits.
- La copie se fait d'abord dans un dossier en_cours_date, renommé seulement à la fin. Si rsync plante, il ne reste pas une version à moitié faite.
- Si le disque n'est pas monté, le script s'arrête, sinon il remplirait le disque du système.
- Le disque est monté avec son UUID dans fstab. Sur notre VM, sda et sdb se sont inversés entre deux démarrages, donc avec /dev/sdb on aurait pu monter le mauvais disque.
- installer.sh prépare le disque seulement s'il n'est pas déjà dans fstab, et seulement un disque vide (sans partition ni système de fichiers). Il ne reformate jamais un disque qui a déjà des sauvegardes.
- /sauvegardes est en 700 root parce qu'il contient une copie de /etc/shadow.

### 2.6 Services en écoute (D2)

Résultat de `ss -tulpn` :

| Port | Programme | Pourquoi |
|---|---|---|
| tcp 22 | sshd | c'est le seul service qu'on veut |
| udp 68 | dhcpcd | client DHCP de la carte NAT, il reçoit son adresse IP du serveur DHCP de VirtualBox. C'est un client, il ne propose pas de service. |
| udp 546 | dhcpcd | pareil en IPv6 |

En plus, le pare-feu bloque tout sauf le port 22.

### 2.7 Fichiers SUID et fichiers modifiables par tous (D3)

Il n'y a aucun fichier modifiable par tout le monde en dehors de /tmp et /var/tmp. Dans la recherche on exclut /proc, /sys, /dev et /run qui sont des systèmes de fichiers virtuels, et find ne suit pas les liens symboliques.

Les fichiers SUID root sur la VM :

| Fichier | À quoi il sert |
|---|---|
| /usr/bin/passwd | changer son mot de passe (il doit écrire dans /etc/shadow) |
| /usr/bin/sudo | il a besoin d'être root pour appliquer les règles sudoers |
| /usr/bin/su | changer d'utilisateur, pas très utile ici car root est verrouillé |
| /usr/bin/chfn et /usr/bin/chsh | changer ses infos ou son shell, pas utile sur ce serveur |
| /usr/bin/gpasswd et /usr/bin/newgrp | gérer et changer de groupe |
| /usr/bin/mount et /usr/bin/umount | monter des disques marqués "user" dans fstab (il n'y en a pas) |
| /usr/lib/dbus-1.0/dbus-daemon-launch-helper | lance des services pour dbus, seul le groupe messagebus peut l'exécuter |
| /usr/lib/openssh/ssh-keysign | sert pour l'authentification host-based, qui n'est pas activée |

On les a laissés parce qu'ils viennent de Debian et sont mis à jour avec les paquets (su, chfn et chsh pourraient être enlevés). Le test test_D3_suid compare avec cette liste, donc si un nouveau fichier SUID apparaît le test passe en KO.

### 2.8 verifier.sh

- On a mis seulement set -u et pas set -e : le script lance exprès des commandes qui doivent échouer (par exemple un chercheur qui essaie d'écrire dans donnees_brutes). Avec set -e il s'arrêterait au premier refus.
- Les tests de droits sont faits avec sudo -u et les noms des comptes viennent de comptes.csv.
- Le script ne modifie rien, les fichiers de test sont supprimés tout de suite.

## 3. Défense

**Force brute SSH** : les mots de passe sont refusés, donc essayer des mots de passe ne sert à rien. En plus il y a 3 essais max par connexion, fail2ban bannit l'IP après 5 échecs et analyse_logs.sh la signale. On l'a testé depuis le PC : après 6 tentatives l'IP 10.0.2.2 a été bannie et le rapport était en alerte.
Ce que ça ne couvre pas : une attaque qui vient de beaucoup d'IP différentes, chacune reste sous le seuil.

**Vol de mot de passe** : un mot de passe volé ne permet pas de se connecter en SSH. Celui d'un admin sert seulement pour sudo une fois connecté avec sa clé.
Ce que ça ne couvre pas : le vol d'une clé privée. Nos clés de test n'ont pas de phrase de passe, en vrai il en faudrait une (ou une double authentification pour les admins).

**Utilisateur curieux** : un doctorant ne peut pas écrire dans /srv/publications, un technicien ne peut pas lire /srv/analyses, personne ne peut lire le dossier perso des autres ni les sauvegardes. C'est testé dans verifier.sh.
Ce que ça ne couvre pas : un admin peut tout lire avec sudo, et on ne garde pas de trace de qui a lu quoi (il faudrait auditd).

**Compte invité piraté** : pas de shell, pas de terminal, pas de tunnel, seulement du SFTP en lecture sur /srv/publications.
Ce que ça ne couvre pas : on n'a pas mis de ChrootDirectory, donc en SFTP un invité peut quand même voir les fichiers du système lisibles par tous (comme /etc/passwd).

**Compte support piraté** : il ne peut lancer qu'un seul script en root, qu'il ne peut pas modifier, et les options sont vérifiées.
Ce que ça ne couvre pas : une faille dans le script ou dans journalctl.

**Fichier supprimé par erreur ou rançongiciel** : on garde 7 versions, on peut revenir à une version d'avant.
Ce que ça ne couvre pas : les sauvegardes sont sur la même machine (c'est une simplification du sujet). Si la VM est volée, tombe en panne ou si un attaquant devient root, on perd aussi les sauvegardes. En entreprise il faudrait suivre la règle 3-2-1.

## 4. Procédure de restauration

Le test qu'on a fait : pdurand (chercheur) écrit /srv/publications/rapport.txt, une sauvegarde passe, puis le fichier est écrasé par erreur ("FICHIER CASSE") et une autre sauvegarde passe.

1. Se connecter avec un admin et passer root, car /sauvegardes est en 700 root :
   ```
   sudo -i
   ```
2. Regarder ce que contient le fichier dans chaque version :
   ```
   for v in /sauvegardes/20*/; do echo "$v : $(cat $v/srv/publications/rapport.txt 2>/dev/null)"; done
   ```
   La version 2026-10-30_050117 a le bon contenu, la 2026-10-30_050129 a la version cassée.
3. Restaurer le fichier depuis la bonne version, avec -aAX pour garder les droits et les ACL :
   ```
   rsync -aAX /sauvegardes/2026-10-30_050117/srv/publications/rapport.txt /srv/publications/
   ```
4. Vérifier :
   ```
   cat /srv/publications/rapport.txt
   getfacl -p /srv/publications/rapport.txt
   ```
   On retrouve "resultats experience 12 : OK", avec pdurand comme propriétaire et les bonnes ACL.

Pour un dossier entier c'est la même commande avec le dossier. On peut aussi restaurer d'abord dans un dossier temporaire pour comparer avant d'écraser.

Remarque : la première fois on a lancé `sudo ls /sauvegardes/20*/` et ça n'a rien trouvé. Le `*` est remplacé par notre shell avant sudo, et notre compte n'a pas le droit de lire /sauvegardes. Il faut lancer toute la commande en root (`sudo -i` ou `sudo bash -c '...'`). Ça montre aussi que B3 marche.
