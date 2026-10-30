# Projet XTI302-CYB - Durcir un serveur Linux et le prouver

Kilian NIVET - B2 Cyber (projet fait seul)

**Contexte C : laboratoire BioLab.** Le serveur héberge les données du labo dans `/srv` :

| Répertoire | technique | chercheurs | doctorants | invite |
|---|---|---|---|---|
| /srv/donnees_brutes | lecture/écriture | lecture | lecture | - |
| /srv/analyses | - | lecture/écriture | lecture/écriture | - |
| /srv/publications | - | lecture/écriture | lecture | lecture |

Les invités n'ont pas de shell (`nologin`), ils peuvent seulement récupérer des fichiers en SFTP.

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `installer.sh` | reconstruit toute la config sur la VM vierge |
| `creer_comptes.sh` | crée groupes, comptes, dossiers de /srv, ACL et installe les clés publiques |
| `comptes.csv` | liste des comptes (aucun mot de passe dedans) |
| `analyse_logs.sh` | rapport des connexions SSH, code de sortie 2 si alerte |
| `sauvegarde.sh` | sauvegarde versionnée et incrémentale de /srv et /etc |
| `verifier.sh` | 47 tests, un par fonction, code de sortie 0 si tout est conforme |
| `config/` | configs SSH, sudoers, nftables, fail2ban, journald, apt, cron, liste des SUID, clés publiques |
| `DOSSIER.md` | tableau de conformité, choix techniques, défense, restauration |

## Prérequis

- VM Debian 13 minimale (VirtualBox) avec un compte qui a sudo (sur l'image utilisée : `debian`).
- Un **second disque vide** de 2 Go pour les sauvegardes. installer.sh le trouve tout seul (disque sans partition ni système de fichiers, moins de 10 Go), le formate en ext4 et le monte sur `/sauvegardes` par UUID. Il le fait seulement si `/sauvegardes` n'est pas déjà dans `/etc/fstab`, donc relancer l'installer ne reformate jamais le disque.
- Réseau : une carte NAT (accès internet pour apt) et une carte host-only (192.168.56.10) pour se connecter depuis l'hôte.
- Côté hôte : les clés privées de test (knivet, support, jleroy, mfaure). Elles ne sont **pas** dans le dépôt, seules les `.pub` sont dans `config/keys/`.

## Installation

Depuis l'hôte, copier le dépôt dans la VM :

```
scp -r xti302-projet-biolab debian@192.168.56.10:~/
```

Puis dans la VM :

```
cd ~/xti302-projet-biolab
chmod +x *.sh
sudo ./installer.sh
```

L'installer demande de choisir le mot de passe de l'admin `knivet` (il en a besoin pour sudo, la connexion SSH se fait par clé).

**Attention :** à la fin, le compte `debian` perd sudo et son mot de passe, et root est verrouillé. Il faut se reconnecter avec l'admin :

```
ssh -i ~/.ssh/biolab/knivet knivet@192.168.56.10
```

L'installer peut être relancé sans problème (il ne recrée pas les comptes et ne touche pas aux sauvegardes).

## Vérification

```
sudo ./verifier.sh
echo $?
```

Chaque test affiche `[OK]` ou `[KO]` avec l'exigence (C1, S2, J4...). À la fin : `--- 47 / 47 tests reussis` et code de sortie 0. Si un test est KO le code de sortie est 1.

## Utilisation au quotidien

- Rapport SSH : `sudo analyse_logs.sh` (options : `-s seuil`, `-p "2 days ago"`, `-f fichier`). Le compte `support` peut lancer cette commande avec sudo, et seulement elle.
- Sauvegarde : automatique tous les jours à 2h (`/etc/cron.d/sauvegarde`), journal dans `/var/log/sauvegarde.log`. À la main : `sudo sauvegarde.sh`.
- Débannir une IP : `sudo fail2ban-client set sshd unbanip <ip>`.
- Restaurer un fichier : voir la partie 4 de `DOSSIER.md`.
