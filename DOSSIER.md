# Dossier - Durcissement du serveur BioLab

Kilian NIVET - B2 Cyber - XTI302-CYB - contexte C (BioLab), projet fait seul.

Références utilisées : guide ANSSI-BP-028 *Recommandations de configuration d'un système GNU/Linux* (noté BP-028), guide ANSSI *Usage sécurisé d'(Open)SSH* (noté ANSSI SSH), pages de manuel.

## 1. Tableau de conformité

| Exig. | Ce que j'ai fait | Test(s) dans verifier.sh | ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv`, crée les groupes qui manquent, crée le compte s'il existe pas puis fait `usermod` à chaque fois (relancer = pas de doublon, pas d'erreur). | `test_C1_comptes` (relit le csv), `test_C1_doublons`, `test_C1_invite_nologin` | BP-028 R33 (comptes nominatifs) |
| C2 | Dossiers de /srv en `700 root:root` + ACL par groupe, et les mêmes en ACL par défaut (`setfacl -d`) pour les fichiers créés plus tard. | 8 tests `test_C2_*` : ce qui doit marcher (technique écrit dans donnees_brutes...) et ce qui doit être refusé (chercheur n'écrit pas dans donnees_brutes...), + `test_C2_acl_defaut` | BP-028 R50 |
| C3 | `/etc/sudoers.d/biolab` : `%admins` a tout, `support` a seulement `/usr/local/sbin/analyse_logs.sh`. Le compte `debian` de l'image est retiré du groupe sudo. Fichier vérifié avec `visudo -c` avant d'être copié. | `test_C3_admins`, `test_C3_support`, `test_C3_personne_dautre` | BP-028 R38, R39, R43 |
| C4 | `passwd -l root`, dossiers perso en 700. | `test_C4_root_verrouille`, `test_C4_homes` | BP-028 R33, R50 |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`. | `test_S1_config`, `test_S1_connexion_mdp_refusee` (vraie tentative de connexion) | ANSSI SSH (authentification par clé) |
| S2 | `PermitRootLogin no` | `test_S2_root` | ANSSI SSH |
| S3 | `AllowGroups acces_ssh` | `test_S3_allowgroups` | ANSSI SSH |
| S4 | `MaxAuthTries 3`, `LoginGraceTime 30`, `ChannelTimeout session=15m`, `ClientAliveInterval 300` x `ClientAliveCountMax 3`. Invités : `ForceCommand internal-sftp`, pas de TTY ni de tunnel. | `test_S4_essais`, `test_S4_inactivite`, `test_S4_invite_sftp` | ANSSI SSH, BP-028 R32 |
| S5 | `config/ssh/sshd_config.d/01-biolab.conf`, `sshd -t` dans installer.sh avant le restart (si erreur : le fichier est enlevé et on arrête). | `test_S5_config` | - |
| J1 | fail2ban, jail sshd : backend systemd, 5 échecs en 10 min, ban 30 min avec nftables. | `test_J1_fail2ban_actif`, `test_J1_config` | BP-028 R79 |
| J2 | `/etc/nftables.conf` : `policy drop` en entrée, on accepte `lo`, `established,related` et le port 22. Service nftables activé au démarrage. | `test_J2_politique_drop`, `test_J2_ssh_autorise`, `test_J2_au_demarrage` | BP-028 R80 |
| J3 | `Storage=persistent` dans `/etc/systemd/journald.conf.d/10-persistent.conf` | `test_J3_persistant` | BP-028 R71 |
| J4 | `analyse_logs.sh` : connexions ratées par IP, comptes visés, connexions réussies. Seuil par défaut 5 (`-s`), code 2 si dépassé. Installé en `755 root`. | `test_J4_installe`, `test_J4_code_retour` (faux log avec 3 échecs : seuil 3 → 2, seuil 10 → 0) | BP-028 R71 |
| B1 | `sauvegarde.sh` : rsync `-aAXH` vers `/sauvegardes/<date>`, `--link-dest` sur la version d'avant, 7 versions gardées. Disque préparé par installer.sh (ext4, monté par UUID). | `test_B1_disque`, `test_B1_version`, `test_B1_acl`, `test_B1_incremental` (même inode), `test_B1_rotation` | - |
| B2 | `/etc/cron.d/sauvegarde` tous les jours à 2h, journal `/var/log/sauvegarde.log` | `test_B2_planifiee`, `test_B2_journal` | - |
| B3 | `/sauvegardes` en `700 root:root` | `test_B3_droits` (un compte technique ne peut pas lister) | BP-028 R50 |
| B4 | Restauration testée (partie 4) | `test_B4_restauration` | - |
| D1 | `unattended-upgrades` + `20auto-upgrades` (liste des paquets et mises à jour de sécu tous les jours) | `test_D1_installe`, `test_D1_active` | BP-028 R61 |
| D2 | Rien d'autre que SSH n'écoute (voir 2.6) | `test_D2_ecoutes` | BP-028 R62, R80 |
| D3 | Aucun fichier modifiable par tous, SUID listés dans `config/suid_attendus.txt` (voir 2.7) | `test_D3_modifiable_par_tous`, `test_D3_suid` | BP-028 R53, R54, R56, R57 |

Résultat sur la VM : `--- 47 / 47 tests reussis`, code de sortie 0.

## 2. Choix techniques

### 2.1 Comptes et droits

- **ACL plutôt que des groupes Unix classiques** : un dossier n'a qu'un seul groupe propriétaire, alors que par exemple /srv/publications doit être en écriture pour chercheurs et en lecture pour doctorants et invités. Les ACL permettent de donner un droit différent à chaque groupe.
- **ACL par défaut** : sans elles, un fichier créé par un chercheur dans /srv/analyses aurait seulement les droits de son umask et les doctorants pourraient pas le modifier. Le test `test_C2_acl_defaut` vérifie exactement ce cas.
- **Base des dossiers en 700 root** : tout est fermé, et on ouvre seulement ce que le tableau demande avec les ACL. Un compte qui est dans aucun groupe métier (debian par exemple) n'a accès à rien.
- **`setfacl -b` à chaque lancement de creer_comptes.sh** : on enlève les anciennes ACL avant de remettre les bonnes, donc si on change le tableau il reste pas d'anciens droits.
- **Mot de passe pour les admins** : ils se connectent par clé, mais sudo demande quand même leur mot de passe. Si la clé d'un admin est volée, l'attaquant a pas root directement. Le mot de passe est demandé par installer.sh et n'est écrit nulle part.
- **support en NOPASSWD sur un seul script** : il a pas de mot de passe, et la règle est limitée à un chemin précis. Le script est en `755 root:root` : si support pouvait le modifier, il mettrait n'importe quelle commande dedans et l'exécuterait en root avec sudo.

### 2.2 SSH

- **Fichier `01-biolab.conf`** : sshd garde la **première** valeur qu'il lit pour chaque option. Avec le préfixe 01 mon fichier est lu avant les autres de sshd_config.d.
- **MaxAuthTries 3** (le sujet autorise 4 max) : avec des clés, un utilisateur normal réussit du premier coup, 3 laisse de la marge si le client essaie plusieurs clés.
- **15 minutes d'inactivité** : `ChannelTimeout session=15m` ferme une session où il se passe rien pendant 15 min. `ClientAliveInterval 300` et `ClientAliveCountMax 3` coupent en plus un client qui répond plus (3 x 5 min).
- **Invités** : `ForceCommand internal-sftp` force le serveur SFTP intégré à sshd, quoi que le client demande. Comme c'est intégré à sshd, ça marche même avec le shell `nologin`. `PermitTTY no` et `AllowTcpForwarding no` empêchent d'avoir un terminal ou d'utiliser le serveur comme rebond.

### 2.3 Pare-feu et fail2ban

- **policy drop + liste de ce qui est autorisé** : plus sûr que bloquer au cas par cas, un nouveau service installé par erreur sera pas joignable.
- **`ct state established,related accept`** : sans ça les réponses aux connexions que le serveur ouvre (apt, DNS) seraient bloquées.
- **Pas de `flush ruleset`** : mon fichier remplace seulement la table `inet filter`. Avec `flush ruleset`, recharger nftables effaçait aussi la table de fail2ban et les IP bannies.
- **fail2ban 5 échecs / 10 min / ban 30 min** : un humain se trompe 1 ou 2 fois. 30 min ralentit énormément une force brute sans bloquer longtemps un vrai utilisateur. Pour me débannir pendant les tests : `fail2ban-client set sshd unbanip <ip>`.
- **backend systemd** : Debian 13 minimale a pas de `/var/log/auth.log`, les logs SSH sont seulement dans le journal.

### 2.4 analyse_logs.sh

- Il lit `journalctl -u ssh` : ça marche que le processus s'appelle `sshd` (Debian 12) ou `sshd-session` (Debian 13).
- **Une connexion ratée = une connexion fermée avant l'authentification** (`Connection closed/reset by ... user`, `Disconnected from ... user`, `Disconnecting ... user`). Avec l'authentification par clé il y a plus de lignes `Failed password`, donc compter que ces lignes donnerait toujours 0. Au début j'avais oublié `Connection reset by`, je l'ai vu en testant une vraie attaque depuis l'hôte.
- **Seuil 5** : le même que fail2ban, un humain arrive pas à 5 connexions ratées depuis la même IP.
- **Le seuil est vérifié (nombre uniquement)** et la sortie de journalctl est mise dans une variable avec `--no-pager` : le script tourne en root via sudo, et un pager comme `less` permet de lancer un shell root (voir GTFOBins).

### 2.5 Sauvegarde

- **Versions + `--link-dest`** : chaque version est un dossier complet, mais les fichiers qui ont pas changé sont des liens durs vers la version d'avant, donc ça prend presque pas de place. Sur la VM, 9 sauvegardes de suite donnent « 0 fichier copié » à partir de la 2e.
- **Pas de miroir** : un miroir recopierait aussi un fichier supprimé ou chiffré par un rançongiciel. Avec les versions on peut revenir en arrière.
- **`-A -X`** pour garder les ACL, sinon une restauration redonnerait des droits faux.
- **Copie dans `en_cours_<date>` puis renommage** : si rsync plante il reste pas une version à moitié faite qui servirait de base à la suivante.
- **Arrêt si le disque est pas monté** : sinon la sauvegarde remplirait le disque système.
- **UUID dans fstab** : sur ma VM, les noms `sda` et `sdb` se sont inversés entre deux démarrages. Avec `/dev/sdb` dans fstab on aurait monté le mauvais disque.
- **installer.sh ne reformate jamais** : il prépare le disque seulement si `/sauvegardes` est pas dans fstab, et seulement un disque sans partition ni système de fichiers.
- **700 root** : la sauvegarde contient une copie de `/etc/shadow`, elle doit être aussi protégée que l'original.

### 2.6 Services en écoute (D2)

Sortie de `ss -tulpn` sur la VM :

| Écoute | Processus | Justification |
|---|---|---|
| tcp 0.0.0.0:22 et [::]:22 | sshd | le seul service voulu |
| udp 10.0.2.15:68 | dhcpcd | client DHCP de la carte NAT : il reçoit les réponses du serveur DHCP de VirtualBox pour avoir une adresse IP. C'est un client, il propose aucun service. |
| udp [...]:546 | dhcpcd | la même chose en IPv6 (client DHCPv6) |

En plus, le pare-feu bloque tout ce qui entre sauf le port 22.

### 2.7 Fichiers SUID et modifiables par tous (D3)

Aucun fichier modifiable par tous en dehors de /tmp, /var/tmp et des systèmes virtuels (/proc, /sys, /dev, /run). La recherche utilise `-prune` pour pas parcourir ces systèmes de fichiers virtuels, et `find` suit pas les liens symboliques par défaut (pas de `-L`).

Fichiers SUID root présents :

| Fichier | Pourquoi il est SUID |
|---|---|
| /usr/bin/passwd | un utilisateur doit pouvoir changer son mot de passe, donc écrire dans /etc/shadow |
| /usr/bin/sudo | il doit passer root pour appliquer les règles de sudoers |
| /usr/bin/su | changer d'utilisateur (inutile ici car root est verrouillé, on pourrait l'enlever) |
| /usr/bin/chfn, /usr/bin/chsh | modifier ses infos ou son shell dans /etc/passwd (pas utile sur ce serveur, candidats à enlever) |
| /usr/bin/gpasswd, /usr/bin/newgrp | gestion et changement de groupe |
| /usr/bin/mount, /usr/bin/umount | monter les volumes marqués `user` dans fstab (aucun ici) |
| /usr/lib/dbus-1.0/dbus-daemon-launch-helper | lance des services système pour dbus, seulement exécutable par le groupe messagebus |
| /usr/lib/openssh/ssh-keysign | sert à l'authentification « host-based », désactivée par défaut |

Je les ai gardés parce qu'ils font partie de Debian et sont mis à jour par les paquets. `test_D3_suid` compare avec cette liste : un nouveau fichier SUID (porte dérobée par exemple) fait passer le test en KO.

### 2.8 verifier.sh

- `set -u` seulement, pas `set -e` ni `pipefail` : le but du script est de lancer des commandes qui doivent échouer (un chercheur qui essaie d'écrire dans donnees_brutes). Avec `set -e` le script s'arrêterait au premier refus normal.
- Les tests de droits se font avec `sudo -u <compte>`, et les noms des comptes sont pris dans `comptes.csv`.
- Il modifie rien : les fichiers de test (`.verif`, faux log) sont supprimés juste après.

## 3. Défense

**1. Force brute sur SSH.** Le mot de passe est refusé (clé obligatoire), donc deviner un mot de passe sert à rien. En plus, 3 essais par connexion, fail2ban bannit l'IP après 5 échecs, et analyse_logs.sh la signale. Testé depuis l'hôte : 6 tentatives, IP 10.0.2.2 bannie, rapport en alerte (code 2).
*Pas couvert :* une attaque répartie sur beaucoup d'IP différentes (chacune reste sous le seuil).

**2. Vol de mot de passe.** Un mot de passe volé permet pas de se connecter en SSH. Celui d'un admin sert seulement pour sudo, une fois connecté avec sa clé.
*Pas couvert :* le vol d'une clé privée. Les clés de test ont pas de phrase de passe : en vrai il en faudrait une, ou une double authentification pour les admins.

**3. Utilisateur curieux.** Un doctorant peut pas écrire dans /srv/publications, un technicien peut pas lire /srv/analyses, personne peut lire le dossier perso des autres (700), ni les sauvegardes (700 root). Testé dans verifier.sh.
*Pas couvert :* un admin peut tout lire avec sudo. Il y a pas de journal de qui a lu quel fichier (il faudrait auditd).

**4. Compte invité compromis.** Pas de shell, pas de terminal, pas de tunnel : seulement SFTP, et en lecture sur /srv/publications.
*Pas couvert :* sans `ChrootDirectory`, l'invité peut parcourir en SFTP les fichiers lisibles par tous du système (par exemple /etc/passwd). Un chroot sur /srv/publications serait mieux.

**5. Compte support compromis.** Il peut lancer qu'un seul script en root, qui lui appartient pas et qu'il peut pas modifier. Les arguments sont vérifiés.
*Pas couvert :* une faille dans le script lui-même ou dans journalctl.

**6. Suppression par erreur ou rançongiciel.** 7 versions datées, on peut revenir à l'état d'avant.
*Pas couvert :* les sauvegardes sont sur la même machine (simplification du sujet). Un vol de la VM, une panne complète ou un attaquant root les ferait disparaître aussi. En entreprise il faudrait la règle 3-2-1 (une copie sur une autre machine, une hors site).

## 4. Procédure de restauration

Exemple testé sur la VM : un chercheur écrit `/srv/publications/rapport.txt`, une sauvegarde passe, puis le fichier est écrasé par erreur (« FICHIER CASSE ») et une autre sauvegarde passe.

1. Se connecter en admin et passer root (le dossier est en 700 root, même la liste des versions demande root) :
   ```
   sudo -i
   ```
2. Chercher dans quelles versions le fichier existe et ce qu'il contient :
   ```
   for v in /sauvegardes/20*/; do echo "$v : $(cat $v/srv/publications/rapport.txt 2>/dev/null)"; done
   ```
   Résultat : la version `2026-10-30_050117` contient la bonne version, `2026-10-30_050129` contient la version cassée.
3. Restaurer depuis la bonne version, avec ses droits et ses ACL (`-aAX`) :
   ```
   rsync -aAX /sauvegardes/2026-10-30_050117/srv/publications/rapport.txt /srv/publications/
   ```
4. Vérifier le contenu et les droits :
   ```
   cat /srv/publications/rapport.txt
   getfacl -p /srv/publications/rapport.txt
   ```
   Résultat : « resultats experience 12 : OK », propriétaire pdurand, groupe chercheurs, ACL chercheurs/doctorants/invite revenues.

Pour un dossier entier c'est pareil avec le dossier comme source (`.../srv/analyses/` vers `/srv/analyses/`). Pour ne rien écraser, on peut d'abord restaurer dans un dossier temporaire et comparer.

**Erreur faite pendant le test :** j'ai lancé `ls /sauvegardes/20*/` sans être root. Le `*` est remplacé par mon shell avant sudo, et mon compte peut pas lire /sauvegardes, donc rien trouvé. Il faut faire toute la commande en root (`sudo -i` ou `sudo bash -c '...'`). Ça montre au passage que B3 marche.
