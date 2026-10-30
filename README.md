# Pixelia — durcissement d'un serveur Debian 13 (contexte A) 

Projet XTI302-CYB (Administration systèmes avancée et scripting), Efrei Paris.
Binôme : Clémence Nagel, Tony Wong.

Le dépôt reconstruit à lui seul un serveur Debian 13 durci pour l'agence Pixelia :
comptes et droits, SSH, pare-feu, fail2ban, journaux, mises à jour et sauvegardes.
`installer.sh` applique tout ; `verifier.sh` prouve la conformité (43 tests : 37 pour le
cahier des charges, 6 pour les recommandations ajoutées en bonus).

## Prérequis

- VM Debian 13 minimale (serveur SSH seul), 2 Go de RAM.
- Second disque **vide** de 1 à 2 Go, vu comme `/dev/sdb` (réservé aux sauvegardes).
- Un compte d'installation avec sudo (le compte créé à l'installation de Debian).
- Accès Internet vers les dépôts Debian officiels.
- La clé publique de chaque administrateur dans `config/cles/<login>.pub`.

## Installation

```bash
sudo apt install -y git
sudo git clone https://github.com/clemhxr-dev/projet-adminsys.git /opt/projet-adminsys
cd /opt/projet-adminsys
sudo ./installer.sh          # demande le mot de passe des administrateurs qui n'en ont pas
```

Le dépôt est cloné en root dans `/opt` : ses scripts sont lancés via sudo, ils doivent
appartenir à root. Après l'installation, le compte créé avec Debian n'a plus ni sudo ni
SSH (C3, S3) : on continue avec un compte administrateur, qui lit `/opt/projet-adminsys`.

`installer.sh` est idempotent : il peut être relancé autant de fois que nécessaire,
il remet le serveur dans l'état décrit par le dépôt.

Garde une session SSH ouverte pendant l'installation et teste la connexion dans une
seconde session avant de fermer la première.

## Vérification

```bash
sudo ./verifier.sh           # code 0 si tout est conforme, 1 sinon
```

Juste après la première installation, une seule sauvegarde existe : lancer
`sudo systemctl start sauvegarde.service` puis relancer `verifier.sh` pour prouver
le caractère incrémental (test B1).

## Audit avant / après (bonus)

`audit.sh` installe Lynis et ssh-audit, puis enregistre dans `audits/` leurs rapports et la
sortie de `verifier.sh`. Depuis la VM vierge :

```bash
sudo ./audit.sh avant
sudo ./installer.sh
sudo systemctl start sauvegarde.service   # seconde sauvegarde (test B1)
sudo ./audit.sh apres                     # audits/resume.md compare les deux états
```

## Contenu du dépôt

| Fichier | Rôle |
| --- | --- |
| `comptes.csv` | comptes, noms et groupes (source unique des comptes) |
| `creer_comptes.sh` | groupes, comptes, clés SSH, répertoires `/srv` et ACL (C1, C2, C4) |
| `installer.sh` | script principal : installe et configure tout, dans un ordre sûr |
| `analyse_logs.sh` | rapport des connexions SSH, alerte au-delà d'un seuil (J4) |
| `sauvegarde.sh` | sauvegarde incrémentale versionnée de `/srv` et `/etc` (B1) |
| `verifier.sh` | 43 tests de conformité, une fonction par exigence |
| `audit.sh` | audits Lynis, ssh-audit et `verifier.sh`, avant et après installation (bonus) |
| `audits/` | rapports produits par `audit.sh` ; `resume.md` compare les deux états |
| `config/cles/` | clés **publiques** des comptes (jamais de clé privée) |
| `config/sudoers.d/10-projet` | règles sudo (C3) |
| `config/ssh/sshd_config.d/50-projet.conf` | durcissement SSH (S1 à S4, algorithmes en bonus) |
| `config/fail2ban/jail.d/sshd-projet.conf` | jail fail2ban (J1) |
| `config/nftables.conf` | pare-feu (J2) |
| `config/journald.conf.d/persistent.conf` | journal persistant (J3) |
| `config/apt/20auto-upgrades` | mises à jour automatiques (D1) |
| `config/systemd/sauvegarde.{service,timer}` | planification des sauvegardes (B2) |
| `config/suid_attendus.txt` | fichiers SUID/SGID présents et justifiés (D3) |
| `config/sysctl.d/99-zz-projet.conf` | paramètres du noyau (bonus, ANSSI R9 à R14) |
| `config/modprobe.d/projet.conf` | modules du noyau inutiles, interdits (bonus, R10) |
| `config/systemd/tmp.mount.d/noexec.conf` | `/tmp` sans exécution (bonus, R28) |
| `config/apt/50extracttemplates` | scripts debconf exécutés hors de `/tmp` (bonus, R28) |
| `DOSSIER.md` | conformité, choix techniques, défense, restauration |

## Comptes

| Login | Rôle | Accès SSH | sudo |
| --- | --- | --- | --- |
| `clemence`, `twong` | administrateurs (groupe `admins`) | oui, par clé | complet, avec mot de passe |
| `support` | compte de support | oui, par clé | `analyse_logs.sh` uniquement |
| `jdupont`, `tmuller` | dev | non | non |
| `lbernard`, `smorin` | design | non | non |
| `proux`, `edurand` | commercial | non | non |
| `fpetit`, `cleroi` | freelance (expiration le 31/01/2027) | non | non |

Pour ajouter un administrateur : une ligne dans `comptes.csv`, sa clé publique dans
`config/cles/<login>.pub`, puis `sudo ./installer.sh`.
