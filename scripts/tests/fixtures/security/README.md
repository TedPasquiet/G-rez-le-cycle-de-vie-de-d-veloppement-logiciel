# Fixtures de `collect_security.py`

⚠️ **Tout ce répertoire est FABRIQUÉ.** Aucun de ces fichiers n'est un rapport
réel : les identifiants sont en `CVE-2099-…`, les paquets s'appellent
`paquet-fictif`, les registres sont en `.invalid`. Ils ont la forme des rapports
de Trivy 0.69.3 et d'OWASP Dependency-Check, réduite aux champs que le
collecteur lit.

Ils sont volontairement petits. Un rapport réel pèse plusieurs centaines de
kilo-octets et change à chaque mise à jour de la base de vulnérabilités : en
versionner un ferait dériver les tests sans que le code ait bougé. Les rapports
réels se produisent localement (`trivy-*-report.json`, ignorés par git).

| Fichier                      | Ce qu'il éprouve                                                     |
| ---------------------------- | -------------------------------------------------------------------- |
| `trivy-fs.json`              | 2 vulnérabilités, 4 misconfigurations, 1 secret, une cible sans rien |
| `trivy-image.json`           | scan d'image : composant déduit du nom, sévérité en minuscules       |
| `trivy-vide.json`            | rapport valide sans `Results` : zéro MESURÉ                          |
| `trivy-invalide.json`        | JSON tronqué : erreur, jamais un zéro                                |
| `pas-un-rapport-trivy.json`  | JSON valide qui n'est pas un rapport : erreur aussi                  |
| `dependency-check.json`      | 2 vulnérabilités, dont une en `moderate`, et une dépendance saine    |
| `dependency-check-vide.json` | aucune dépendance vulnérable : zéro mesuré                           |
| `trivyignore.yaml`           | une exception valide, une échue, une sans chemin ni échéance         |
| `trivyignore-invalide.yaml`  | une entrée sans `id` : erreur                                        |
