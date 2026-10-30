# Projet XTI302-CYB - Durcir un serveur Linux et le prouver

Kilian NIVET et Ethan PICOLO - B2 Cyber

## Contexte

On a choisi le contexte C : le laboratoire BioLab. Le serveur stocke les données du labo dans `/srv` et chaque groupe a des droits différents :

| Répertoire | technique | chercheurs | doctorants | invite |
|---|---|---|---|---|
| /srv/donnees_brutes | lecture/écriture | lecture | lecture | - |
| /srv/analyses | - | lecture/écriture | lecture/écriture | - |
| /srv/publications | - | lecture/écriture | lecture | lecture |

Les invités n'ont pas de shell (nologin), ils peuvent seulement récupérer des fichiers en SFTP.

## Contenu du dépôt

- `installer.sh` : refait toute la configuration sur une VM vierge
- `creer_comptes.sh` : crée les groupes, les comptes, les dossiers de /srv avec les ACL et installe les clés publiques
- `comptes.csv` : la liste des comptes (pas de mot de passe dedans)
- `analyse_logs.sh` : rapport sur les connexions SSH, renvoie 2 si une IP dépasse le seuil
- `sauvegarde.sh` : sauvegarde de /srv et /etc avec des versions datées
- `verifier.sh` : 47 tests pour vérifier toutes les exigences
- `config/` : les fichiers de config (SSH, sudoers, nftables, fail2ban, journald, apt, cron), la liste des SUID et les clés publiques
- `DOSSIER.md` : tableau de conformité, choix techniques, défense et restauration

## Prérequis

- Une VM Debian 13 minimale avec un compte qui a sudo (sur notre image c'est `debian`).
- Un deuxième disque vide de 2 Go pour les sauvegardes. installer.sh le trouve tout seul, le formate et le monte sur `/sauvegardes`. Il le fait seulement si `/sauvegardes` n'est pas déjà dans `/etc/fstab`, comme ça relancer l'installer ne supprime pas les sauvegardes.
- Deux cartes réseau : une en NAT pour internet et une en host-only (192.168.56.10) pour se connecter depuis le PC.
- Sur le PC : les clés privées de test (knivet, epicolo, support, jleroy, mfaure). Elles ne sont pas dans le dépôt, il y a seulement les clés publiques dans `config/keys/`.

## Installation

Copier le dépôt dans la VM depuis le PC :

```
scp -r xti302-projet-biolab debian@192.168.56.10:~/
```

Puis dans la VM :

```
cd ~/xti302-projet-biolab
chmod +x *.sh
sudo ./installer.sh
```

L'installer demande un mot de passe pour chaque admin (knivet et epicolo). Il sert pour sudo, la connexion SSH se fait avec la clé.

Attention : à la fin de l'installation le compte `debian` n'a plus sudo et son mot de passe est bloqué, et root est verrouillé. Il faut donc se reconnecter avec un admin :

```
ssh -i ~/.ssh/biolab/knivet knivet@192.168.56.10
```

On peut relancer installer.sh plusieurs fois sans problème, il ne recrée pas les comptes et ne touche pas aux sauvegardes.

## Vérification

```
sudo ./verifier.sh
echo $?
```

Chaque test affiche `[OK]` ou `[KO]` avec le numéro de l'exigence. À la fin on doit avoir `47 / 47 tests reussis` et un code de sortie 0 (1 s'il y a au moins un KO).

## Commandes utiles

- Rapport SSH : `sudo analyse_logs.sh` (options `-s` pour le seuil, `-p "2 days ago"` pour la période, `-f fichier` pour lire un fichier de log). Le compte support peut lancer cette commande avec sudo et rien d'autre.
- Sauvegarde : elle se lance toute seule tous les jours à 2h, le journal est dans `/var/log/sauvegarde.log`. Pour la lancer à la main : `sudo sauvegarde.sh`.
- Débannir une IP : `sudo fail2ban-client set sshd unbanip <ip>`
- Restaurer un fichier : voir la partie 4 du DOSSIER.
