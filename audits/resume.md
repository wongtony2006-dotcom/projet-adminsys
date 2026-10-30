# Audits Lynis et ssh-audit : avant et après installer.sh

Produit par `audit.sh`. « Avant » : VM Debian 13 vierge ; « après » : après
`installer.sh`. Les deux audits tournent sur la même VM, avec les mêmes outils.

| Mesure | Avant | Après |
| --- | --- | --- |
| verifier.sh : tests réussis | 6 / 43 | 43 / 43 |
| Lynis : indice de durcissement (sur 100) | 63 | 77 |
| Lynis : avertissements | 2 | 1 |
| Lynis : suggestions | 47 | 33 |
| Lynis : tests effectués | 252 | 253 |
| ssh-audit : points « fail » | 6 | 0 |
| ssh-audit : points « warn » | 8 | 0 |
| Date de l'audit | 30/10/2026 09:01 | 30/10/2026 09:04 |

Outils : Lynis 3.1.4-1, ssh-audit 3.3.0-2, OpenSSH_10.0p2 Debian-7+deb13u4.

Détails : `verifier-<état>.txt`, `lynis-<état>.txt` (sortie complète),
`lynis-<état>-points.txt` (avertissements et suggestions), `ssh-audit-<état>.txt`.
