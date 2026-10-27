# Dossier technique — durcissement du serveur Pixelia

Projet XTI302-CYB, contexte A (Pixelia). Binôme : Clémence Nagel, Tony Wong.

Le serveur est une Debian 13 minimale. Toute la configuration vient du dépôt :
`installer.sh` la reconstruit depuis le snapshot vierge et `verifier.sh` la contrôle
par 36 tests (sortie 0 = conforme). Les numéros ANSSI renvoient au guide
« Recommandations de configuration d'un système GNU/Linux » (BP-028, v2.0).

## 1. Tableau de conformité

| Exigence | Réalisation | Tests (`verifier.sh`) | ANSSI BP-028 |
| --- | --- | --- | --- |
| C1 comptes | `comptes.csv` lu par `creer_comptes.sh` ; comptes nominatifs ; freelances expirés le 31/01/2027 (`chage -E`) | `test_C1_comptes`, `test_C1_doublons` | R30 (désactiver les comptes inutilisés), R33 (imputabilité) |
| C2 répertoires partagés | `/srv/*` en `root:root`, aucun droit « other », droits des groupes par ACL d'accès + ACL par défaut | `test_C2_projets`, `_externe`, `_maquettes`, `_clients`, `_acl_par_defaut` | R50 (restreindre l'accès aux fichiers et répertoires sensibles) |
| C3 sudo | `%admins ALL=(ALL:ALL) ALL` ; `support` limité à `/usr/local/sbin/analyse_logs.sh` ; groupe `sudo` vidé | `test_C3_admins`, `_support`, `_personne_dautre`, `_script_protege` | R38 (groupe dédié à sudo), R39 (directives sudo), R43 (préciser les commandes et arguments) |
| C4 root et homes | `passwd -l root` ; `/home/*` en 700 ; `HOME_MODE 0700` pour les futurs comptes | `test_C4_root`, `test_C4_homes` | R33 (administration nominative via sudo), R50 |
| S1 clé uniquement | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey` | `test_S1_config`, `test_S1_refus_mot_de_passe` (vraie tentative) | guide ANSSI OpenSSH |
| S2 root interdit | `PermitRootLogin no` | `test_S2` | R33 |
| S3 groupe autorisé | `AllowGroups acces_ssh` | `test_S3` | guide ANSSI OpenSSH |
| S4 essais et inactivité | `MaxAuthTries 3`, `LoginGraceTime 30`, `ChannelTimeout global=15m`, `ClientAliveInterval 300` × 2 | `test_S4_essais`, `test_S4_inactivite` | R32 (expirer les sessions) |
| S5 configuration validée | fichier dans `sshd_config.d`, `sshd -t` avant redémarrage, refus si aucun admin n'a de clé | `test_S5` | — |
| J1 fail2ban | jail `sshd`, backend `systemd`, 3 échecs / 10 min → 15 min, progressif jusqu'à 1 jour | `test_J1` | défense en profondeur |
| J2 pare-feu | nftables, politique `drop` en entrée, SSH + connexions établies + boucle locale + découverte de voisins IPv6 | `test_J2_politique`, `_ssh_et_etablies`, `_persistant` | R62 (réduire les services exposés) |
| J3 journal persistant | `Storage=persistent`, 200 Mo et 6 mois au plus | `test_J3` | guide ANSSI journalisation |
| J4 analyse des logs | `analyse_logs.sh` : échecs par IP et par compte, réussites, alerte (code 1) au-delà du seuil | `test_J4` | — |
| B1 sauvegardes | `rsync -aAXH --link-dest` : versions datées, incrémentales, ACL conservées, 7 versions gardées | `test_B1_versions`, `_incremental`, `_acl` | — |
| B2 planification | timer systemd quotidien (2 h 30, `Persistent=true`), sortie dans le journal | `test_B2` | — |
| B3 accès restreint | `/sauvegardes` en `root:admins` 750, disque monté `nodev,nosuid,noexec` | `test_B3` | R50 |
| B4 restauration | procédure en section 5, testée | `test_B4` | — |
| D1 mises à jour | `unattended-upgrades`, origine Debian-Security, quotidien | `test_D1` | R59 (dépôts officiels), R61 (mises à jour régulières) |
| D2 services | seul `sshd` écoute ; sockets du client DHCP justifiées | `test_D2` | R58 (paquets nécessaires), R62 (services nécessaires) |
| D3 droits spéciaux | aucun fichier modifiable par tous ; SUID inutiles retirés ; SUID/SGID restants listés et justifiés | `test_D3_ecriture`, `test_D3_suid` | R54 (sticky bit), R56 et R57 (setuid/setgid) |

## 2. Choix techniques

**Comptes et mots de passe.** Seuls les administrateurs ont un mot de passe : il sert à
`sudo` et à la console de l'hyperviseur, seul accès de secours une fois root verrouillé.
Les autres comptes n'ont aucun mot de passe utilisable et se connectent par clé
(`UsePAM yes` l'autorise malgré le compte « verrouillé »). La première version du script
donnait à tous un mot de passe temporaire commun écrit dans le script, avec changement
forcé : un secret partagé versionné dans Git, et un changement forcé qui bloquait la
connexion par clé et `sudo` pour `support`. `creer_comptes.sh` corrige ces comptes.

**ACL.** `setfacl --set` remplace l'ACL entière : relancer le script efface une entrée
ajoutée à la main. L'ACL par défaut (`default:`) fait hériter les droits aux fichiers
créés ensuite. `freelance` a `--x` sur `/srv/projets` : il traverse jusqu'à `externe`
sans pouvoir lister le reste, et n'apparaît pas dans l'ACL par défaut.

**sudo pour support.** La règle vise un chemin absolu dans `/usr/local/sbin`, fichier et
dossier appartenant à root. Si `support` pouvait modifier le script ou son dossier, il y
écrirait `bash -p` et deviendrait root. Le script fixe son `PATH`, appelle `journalctl`
avec `--no-pager` (un pager permet `!sh`) et refuse tout argument hors liste.

**SSH.** Un fichier `50-projet.conf` dans `sshd_config.d` : lu avant `sshd_config`, et la
première valeur lue l'emporte. `ClientAliveInterval` ne coupe qu'un client injoignable ;
`ChannelTimeout global=15m` coupe une session réellement inactive. `installer.sh` refuse
de durcir SSH si aucun administrateur n'a de clé, et valide par `sshd -t`.

**fail2ban.** Debian 13 n'a plus `/var/log/auth.log` (rsyslog n'est plus installé) : la
jail lit le journal systemd. Le mode `aggressive` compte aussi les déconnexions avant
authentification, car avec la clé obligatoire les lignes « Failed password » disparaissent.
Bannissement de 15 minutes, doublé à chaque récidive jusqu'à 1 jour : assez pour casser
un robot, sans bloquer longtemps un utilisateur maladroit. OpenSSH 10 ajoute ses propres
pénalités par adresse (`PerSourcePenalties`).

**Pare-feu.** Pas de `flush ruleset` : il effacerait la table `inet f2b-table` de
fail2ban. Le fichier ne remplace que la table `inet filtre`, et `installer.sh` redémarre
fail2ban après nftables. `drop` plutôt que `reject` : un scan n'obtient aucune réponse.
Les messages ICMPv6 de découverte de voisins restent ouverts, sans quoi l'IPv6 que le
NAT VirtualBox attribue à la VM cesse de fonctionner. Le ping n'est pas autorisé.

**Analyse des logs.** Seuil par défaut : 10 échecs par IP sur 24 h. fail2ban bannit dès
3 échecs en 10 minutes ; une IP qui atteint 10 sur la journée est revenue plusieurs fois
malgré les bannissements. Codes de sortie : 0 rien d'anormal, 1 alerte, 2 erreur d'usage.

**Sauvegardes.** Le second disque n'est formaté que s'il ne porte aucun système de fichiers
et aucune partition ; il est monté par étiquette (`LABEL=SAUVEGARDE`) avec `nofail`.
`--link-dest` crée un lien physique pour chaque fichier inchangé : chaque version paraît
complète mais n'occupe que la place des changements. Une version n'est renommée en date
qu'une fois complète (`.encours` sinon). Le script refuse de tourner si le disque n'est
pas monté. Limite assumée : le disque est dans la même machine, la règle 3-2-1 n'est pas
respectée.

**Mises à jour.** Redémarrage automatique désactivé (réglage par défaut) : une mise à
jour du noyau prend effet au redémarrage planifié par un administrateur.

**Ports en écoute (D2).** `ss -tuln` montre `sshd` (22/tcp) et le client DHCP `dhcpcd`
(68/udp en IPv4, 546/udp en IPv6). Ce ne sont pas des services : ils servent à obtenir
l'adresse IP de la VM. Le pare-feu rejette tout trafic entrant non sollicité vers ces ports.

## 3. Fichiers SUID et SGID (D3)

Retirés par `installer.sh` (`dpkg-statoverride`, conservé lors des mises à jour) :
`/usr/bin/chfn` et `/usr/bin/chsh` (aucun utilisateur n'a à changer son nom ou son shell),
`/usr/lib/openssh/ssh-keysign` (authentification « hostbased », désactivée).

Conservés (`config/suid_attendus.txt`) :

| Fichier | Bit | Justification |
| --- | --- | --- |
| `/usr/bin/passwd` | SUID root | changer son mot de passe = écrire dans `/etc/shadow` |
| `/usr/bin/sudo`, `/usr/bin/su` | SUID root | changer d'identité exige root ; base de C3 |
| `/usr/bin/mount`, `/usr/bin/umount` | SUID root | montages autorisés aux utilisateurs (`user` dans `fstab`) |
| `/usr/bin/newgrp`, `/usr/bin/gpasswd` | SUID root | changer de groupe, gérer un groupe |
| `/usr/lib/dbus-1.0/dbus-daemon-launch-helper` | SUID root, groupe `messagebus` | démarrage des services D-Bus système, exécutable par `messagebus` seulement |
| `/usr/bin/chage`, `/usr/bin/expiry`, `/usr/sbin/unix_chkpwd` | SGID `shadow` | lire `/etc/shadow` sans être root (expiration, vérification du mot de passe) |
| `/usr/bin/crontab` | SGID `crontab` | écrire dans le répertoire des crontabs |
| `/usr/bin/ssh-agent` | SGID `_ssh` | empêche les autres processus de l'utilisateur de lire la mémoire de l'agent |
| `/usr/bin/dotlockfile` | SGID `mail` | verrous sur les boîtes aux lettres |

Recherche des fichiers modifiables par tous : uniquement sur les systèmes de fichiers
réels (`findmnt -t ext4…`, `find -xdev`), pour exclure `/proc`, `/sys` et `/run`, et sur
les vrais fichiers (`-type f`), car tous les liens symboliques apparaissent en 777.

## 4. Défense : ce qui bloque, et ce qui ne bloque pas

| Attaque | Ce qui la bloque | Limite |
| --- | --- | --- |
| Force brute SSH | clé obligatoire, `MaxAuthTries 3`, fail2ban, pénalités OpenSSH | une attaque répartie sur des milliers d'IP contourne le bannissement par IP |
| Vol d'un mot de passe | inutile à distance : SSH n'accepte que les clés | une clé privée volée avec sa phrase de passe ouvre l'accès ; pas de second facteur |
| Utilisateur curieux | homes en 700, ACL par groupe, rien pour « other » dans `/srv` | un membre légitime d'un groupe peut copier ce qu'il lit |
| Compte freelance compromis | pas d'accès SSH, accès limité à `externe`, expiration au 31/01/2027 | une faille du noyau permettrait une élévation de privilèges |
| Compte support compromis | une seule commande en root, script figé par root, arguments filtrés | l'attaquant lit les journaux SSH (adresses IP, logins) |
| Rançongiciel | versions datées : retour à une version antérieure | sauvegardes sur la même machine : un attaquant root les chiffre aussi |

## 5. Procédure de restauration (B4)

```bash
# 1. Lister les versions disponibles (administrateur)
sudo ls /sauvegardes/
# 2. Retrouver les versions qui contiennent le fichier
sudo ls -l /sauvegardes/*/srv/projets/rapport.txt
# 3. Restaurer depuis la version choisie en conservant droits et ACL
sudo rsync -aAX /sauvegardes/2026-10-27_153000/srv/projets/rapport.txt /srv/projets/
# 4. Contrôler le contenu et les droits
sudo getfacl -p /srv/projets/rapport.txt
```

Scénario testé : création de `rapport.txt` par un compte dev, sauvegarde, suppression du
fichier, nouvelle sauvegarde, puis restauration depuis la première version ; le contenu et
les ACL héritées sont retrouvés.

## 6. Résultats

`installer.sh` a été lancé sur la VM déjà configurée (migration depuis la première version
du projet), relancé une seconde fois sans erreur (idempotence), puis lancé depuis le
snapshot vierge. `verifier.sh` : 36 tests sur 36 réussis.

## Sources

- [ANSSI — Recommandations de configuration d'un système GNU/Linux (BP-028 v2.0)](https://messervices.cyber.gouv.fr/guides/recommandations-de-securite-relatives-un-systeme-gnulinux)
- [sshd_config(5), Debian 13 / OpenSSH 10.0](https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html)
- [Notes de version de Debian 13 : rsyslog n'est plus installé par défaut](https://www.debian.org/releases/trixie/release-notes/issues.fr.html)
- [fail2ban sur Debian 13 : backend systemd, nftables, `flush ruleset`](https://www.kernelhost.com/en/blog/set-up-fail2ban)
