# Tableaux de bord Kibana — objets sauvegardés

**Cinq tableaux de bord**, un fichier NDJSON chacun : supervision, DORA,
sécurité, disponibilité, suivi des alertes. Le raisonnement d'ensemble est dans
`MONITORING.md` §8.

**Le livrable n'est pas un écran dans Kibana, c'est un fichier NDJSON.** Un
tableau de bord construit à la souris vit dans l'index `.kibana` d'un pod ; il
disparaît avec le PVC, avec le namespace, avec le `minikube delete`. Le fichier
versionné ici est la seule forme du tableau de bord qui survive à son instance.

## Les cinq fichiers, d'un coup d'œil

| Fichier                | Tableau de bord           | Objets | Données lues                                           |
| ---------------------- | ------------------------- | ------ | ------------------------------------------------------ |
| `microcrm.ndjson`      | `microcrm-dashboard`      | 8      | `microcrm-logs*`                                       |
| `dora.ndjson`          | `dora-dashboard`          | 13     | `microcrm-dora`                                        |
| `securite.ndjson`      | `securite-dashboard`      | 22     | `microcrm-security`, `microcrm-logs*`, `microcrm-dora` |
| `disponibilite.ndjson` | `disponibilite-dashboard` | 18     | `microcrm-logs*`, `traces-apm*`, `microcrm-dora`       |
| `alertes.ndjson`       | `alertes-dashboard`       | 8      | `microcrm-alerts`                                      |

Chaque fichier embarque les vues de données dont il dépend — y compris celles
d'un autre fichier quand il y puise ses annotations. L'ordre d'import n'a donc
pas d'importance.

Les descriptions sont portées par les objets eux-mêmes : elles s'affichent sous
l'icône ⓘ de chaque panneau, donc devant celui qui lit le tableau de bord et non
seulement devant celui qui lit ce fichier. La fenêtre de temps par défaut est
**restaurée à l'ouverture** (`timeRestore`), pour que le tableau de bord montre
des données dès l'import plutôt qu'un écran vide sur une plage de 15 minutes.

## Importer

```shell
kubectl -n logging port-forward svc/kibana 5601:5601
for f in microcrm dora securite disponibilite alertes; do
  curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
    -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/$f.ndjson
done
```

Chaque réponse doit porter `"success":true` et le `successCount` du tableau
ci-dessus. Un `successCount` inférieur signale un objet rejeté, pas un import
partiel acceptable.

**Preuve : import à froid sur Kibana 8.19.7** (objets supprimés de l'instance au
préalable, pour que le test ne soit pas un simple écrasement) :

| Date       | Fichier                | Réponse de l'import                   |
| ---------- | ---------------------- | ------------------------------------- |
| 2026-08-16 | `microcrm.ndjson`      | `"success": true, "successCount": 8`  |
| 2026-10-02 | `securite.ndjson`      | `"success": true, "successCount": 22` |
| 2026-10-02 | `disponibilite.ndjson` | `"success": true, "successCount": 18` |
| 2026-10-02 | `dora.ndjson`          | `"success": true, "successCount": 13` |
| 2026-10-02 | `alertes.ndjson`       | `"success": true, "successCount": 8`  |

## Réexporter après modification

Modifier un tableau de bord dans Kibana ne modifie pas ce dépôt. Toute retouche
faite à la souris doit être réexportée, sinon elle est perdue au prochain
`minikube delete`.

```shell
curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_export' \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"objects":[{"type":"dashboard","id":"microcrm-dashboard"}],
       "includeReferencesDeep":true}' \
  -o k8s/elk/dashboards/microcrm.ndjson
```

Pour un autre fichier, remplacer l'identifiant du tableau de bord et le nom du
fichier (colonnes du premier tableau).

⚠️ `includeReferencesDeep` n'est pas une option de confort. Sans lui, l'export
ne contient que le tableau de bord : la vue de données reste derrière, et la
réimportation produit des panneaux vides derrière un message d'erreur qui ne
nomme pas la cause.

⚠️ **Ne pas retoucher un objet à la main dans le NDJSON.** Un objet sans
`typeMigrationVersion` fait échouer l'import sur
`Cannot read properties of undefined (reading 'layers')` : Kibana rejoue toute
la chaîne de migration 7.x → 8.x. Les objets versionnés ici sont créés dans
l'interface ou par l'API, contrôlés à l'écran, puis **exportés par Kibana** —
c'est ce qui garantit que chacun porte les champs de migration attendus.

## `microcrm.ndjson` — la supervision

| Objet                    | Type            | Rôle                                    |
| ------------------------ | --------------- | --------------------------------------- |
| `microcrm-logs`          | `index-pattern` | vue de données `microcrm-logs*`         |
| `microcrm-volume`        | `lens`          | volume par conteneur                    |
| `microcrm-latence`       | `lens`          | percentiles de latence Caddy            |
| `microcrm-erreurs-back`  | `lens`          | niveaux WARN / ERROR du back            |
| `microcrm-erreurs-http`  | `lens`          | comptage des réponses HTTP >= 400       |
| `microcrm-statuts-http`  | `lens`          | répartition des codes de réponse        |
| `microcrm-derniers-logs` | `search`        | flux brut des événements récents        |
| `microcrm-dashboard`     | `dashboard`     | assemblage, fenêtre `now-24h` restaurée |

### Deux choix de construction

**`caddy.duration` est en secondes.** Affiché tel quel, le p50 vaut `0.00043` —
un axe illisible. La conversion n'est pas faite dans les visualisations mais
**une seule fois, dans le `fieldFormatMap` de la vue de données** : le champ est
déclaré `inputFormat: seconds` / `outputFormat: asMilliseconds`. Tout panneau
qui touche ce champ hérite de l'unité, y compris ceux qui n'existent pas encore.
C'est aussi pourquoi la vue de données doit impérativement faire partie de
l'export.

**`log.level` est une clé plate qui cohabite avec un objet `log` imbriqué.**
Le `_source` d'un document du back contient à la fois `"log.level": "INFO"` et
`"log": {"file": {"path": …}}`. Elasticsearch les fusionne au mapping et Kibana
les résout par l'API `fields`, donc filtrage et affichage fonctionnent. Vérifié :
`log.level: *` renvoie dans Kibana exactement le nombre de documents qu'une
agrégation `terms` compte sur Elasticsearch (54 = 52 `INFO` + 2 `WARN`). Le
pipeline d'ingestion évoqué en `MONITORING.md` §12 reste souhaitable pour la
propreté, mais il n'est pas nécessaire à ces écrans.

### Ce que ces écrans ne disent pas

**La latence est celle du front, jamais celle de l'API.** `caddy.duration` est
le temps de service du serveur web qui sert l'application Angular. Les appels
au back partent du navigateur vers l'hôte de l'API et ne traversent jamais le
front. Un p99 à 2 ms dit que Caddy sert vite des fichiers, rien de plus. La
latence de l'API vient des traces (`MONITORING.md` §10), lues par le tableau
`disponibilite`.

**L'écran des erreurs HTTP est vide par construction.** Le front sert une SPA
avec `try_files … /index.html` : tout chemin inconnu renvoie 200 avec la page,
et c'est Angular qui décide ensuite qu'il n'y a rien à cette adresse. Un 404 ne
peut donc pas apparaître dans les logs de Caddy. Le zéro affiché est le
comportement attendu du routage, pas une preuve d'absence d'erreur — d'où le
titre du panneau, qui le dit. Les erreurs observables sont celles du back,
panneau voisin.

**Le volume compte des lignes de log, pas des requêtes.** Une requête peut
n'en produire aucune, un démarrage en produit cinquante.

**Les erreurs du back ne couvrent que les lignes encodées en ECS.** La bannière
ASCII de Spring Boot et les quelques lignes émises avant l'initialisation de
Logback n'ont pas de champ `log.level` : elles sont invisibles à ce panneau.

**Le front n'a pas de `log.level`, et son `message` reste le JSON brut.** Son
journal est décodé sous le préfixe `caddy` (`MONITORING.md` §4) pour ne pas
entrer en collision avec l'espace ECS : ses champs exploitables sont
`caddy.status`, `caddy.duration`, `caddy.request.uri`, jamais `log.level`. Un
tiret dans la colonne `log.level` de la table signale une ligne du front, pas
une anomalie.

**Ces écrans se regardent ; ce ne sont pas eux qui préviennent.** Les huit
règles d'alerte (`../alerting/`) lisent les mêmes index ; ce qu'elles écrivent se
consulte dans `alertes.ndjson`. Aucune notification ne sort de Kibana
(`MONITORING.md` §11.5), et sans ILM l'historique s'arrête là où le PVC se
remplit.

## Les annotations

Trois graphiques portent des **annotations Lens par requête** : des marqueurs
verticaux calculés à l'affichage, pas dessinés à la main. Elles lisent l'index
`microcrm-dora` (les jobs de déploiement et de rollback relevés par
`collect_dora.py`), sauf la dernière qui lit les logs :

| Marqueur           | Requête                                                                | Où                                                          |
| ------------------ | ---------------------------------------------------------------------- | ----------------------------------------------------------- |
| Déploiement réussi | `type: "evenement" and categorie: "deploiement" and statut: "success"` | évolution des constats, erreurs du back, sondes, démarrages |
| Rollback           | `type: "evenement" and categorie: "rollback"`                          | les mêmes, et la chronologie DORA                           |
| Démarrage du back  | ligne `Started MicroCRMApplication` dans `microcrm-logs*`              | sondes du front                                             |

Ce qu'elles permettent de lire : un pic de `WARN` posé sur un marqueur de
déploiement est le démarrage d'un pod, pas une anomalie ; un trou dans les
sondes sans marqueur est une collecte arrêtée, pas une mise en production.

⚠️ **Une annotation n'apparaît que si l'index `microcrm-dora` est à jour.**
Aucun job ne l'alimente dans le cluster : il faut rejouer `collect_dora.py` avec
`--elasticsearch` après un déploiement (`MONITORING.md` §9.5), sinon le marqueur
manque — et son absence ne veut pas dire « pas de déploiement ».

⚠️ Les champs affichés dans l'infobulle d'une annotation (`extraFields`) doivent
être **agrégeables**. `job` est un champ `text` dans `microcrm-dora` (mapping
dynamique) : le citer tel quel fait échouer tout le panneau sur
`Tooltip fields job not found in data view`. C'est `job.keyword` qu'il faut
nommer.

## `securite.ndjson`

22 objets. Les constats viennent de l'index `microcrm-security`, alimenté par
`scripts/ci/collect_security.py` (voir `SCRIPTS.md`) ; les trois derniers
panneaux lisent les logs.

```shell
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &
python3 scripts/ci/collect_security.py \
  --trivy-report reports/trivy-fs.json \
  --trivy-report reports/trivy-image-back.json \
  --trivy-report reports/trivy-image-front.json \
  --dependency-check-report back/build/reports/dependency-check-report.json \
  --optional --elasticsearch http://127.0.0.1:9200
```

| Panneau                                    | Ce qu'il mesure                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------ |
| Comment lire ce tableau de bord            | texte : origine des chiffres, zéro mesuré, limites                       |
| Scans pris en compte                       | nombre de documents `type: scan`, `courant: true`                        |
| Constats CRITICAL / HIGH ouverts           | somme de `par_severite.CRITICAL` / `.HIGH` sur les scans courants        |
| Constats ouverts, toutes sévérités         | somme de `ouverts` sur les scans courants                                |
| Constats exceptés                          | somme de `exceptes` sur les scans courants                               |
| Exceptions assumées                        | nombre de documents `type: exception`                                    |
| Jours avant la première échéance           | minimum de `jours_restants` sur les exceptions                           |
| Constats ouverts par cible et par sévérité | constats courants ouverts, par `composant` (back / front / depot)        |
| Constats ouverts par scan et par sévérité  | les mêmes, par `source` (`trivy-fs:depot`, `trivy-image:back`, …)        |
| Constats ouverts par nature                | les mêmes, par `categorie` (vulnérabilité, misconfiguration, secret)     |
| Constats HIGH et CRITICAL dans le temps    | `max(hauts_critiques)` par jour et par source, **annoté**                |
| Constats ouverts dans le temps             | `max(ouverts)` par jour et par source                                    |
| Vulnérabilités et constats HIGH / CRITICAL | table : une ligne par constat courant ouvert de ces deux sévérités       |
| Exceptions assumées et leur échéance       | table : identifiant, chemin, échéance, jours restants, constats couverts |
| Réponses 401 / 403 vues par le front       | nombre de documents `caddy.status: (401 or 403)`                         |
| Réponses HTTP 4xx du front                 | `caddy.status >= 400` dans le temps, par code                            |
| Erreurs applicatives du back               | lignes `log.level` WARN et ERROR dans le temps, **annoté**               |

**Confrontation à Elasticsearch, 2026-10-02** (agrégations équivalentes, fenêtre
de 90 jours) — chaque valeur est celle que le panneau affiche :

| Panneau                             | Kibana                                | Elasticsearch                                  |
| ----------------------------------- | ------------------------------------- | ---------------------------------------------- |
| Scans pris en compte                | `3`                                   | 3 documents `scan` courants                    |
| CRITICAL / HIGH ouverts             | `0` / `5`                             | `sum` = 0 / 5                                  |
| Ouverts / exceptés                  | `80` / `11`                           | `sum` = 80 / 11                                |
| Exceptions / première échéance      | `7` / `90`                            | 7 documents, `min(jours_restants)` = 90        |
| Par cible                           | depot 56, back 13, front 11           | `terms` sur `composant.keyword` : 56 / 13 / 11 |
| Par scan                            | 58 / 12 / 10                          | `terms` sur `source.keyword` : 58 / 12 / 10    |
| Par nature                          | misconfiguration 58, vulnérabilité 22 | `terms` sur `categorie.keyword` : 58 / 22      |
| Table HIGH / CRITICAL               | `5 documents`                         | `_count` = 5                                   |
| Réponses 401 / 403, réponses >= 400 | `0`, « No results found »             | 0 et 0 document                                |
| WARN / ERROR                        | WARN seul                             | 52 WARN, 0 ERROR                               |

Les cinq constats HIGH de ce relevé sont cinq CVE de `jackson-core` /
`jackson-databind` 2.21.4 dans l'image `back:5bf1d6a2`. Les images construites
depuis forcent Jackson 2.21.7 (`back/build.gradle`) et leurs rapports Trivy ne
portent aucun constat HIGH ou CRITICAL ; l'index n'ayant pas été réalimenté, le
tableau de bord montre toujours le relevé du 2026-10-02.

### Ce que cet écran ne dit pas

**L'historique est rejoué, pas vécu.** Huit commits (du 2026-08-01 au
2026-10-02) ont été exportés par `git archive` et scannés avec Trivy 0.69.3,
ainsi que les images du registry portant leur tag quand elles existent
(`50a07951`, `34df46de`, `234ab50a`, `5bf1d6a2`). Chaque scan est daté du
commit, mais jugé avec la base de vulnérabilités **du 2026-10-02**. La courbe
dit donc « ce que ces versions contiennent de vulnérable au regard de ce qu'on
sait à cette date », pas « ce que le pipeline voyait ce jour-là ». Les
exceptions appliquées à chaque point sont celles du `.trivyignore.yaml` **de ce
commit**.

**Les rapports rejoués sont plus larges que ceux de la CI.** Ils sont produits
sans filtre de sévérité et sans `--ignorefile`, pour que MEDIUM, LOW et constats
exceptés apparaissent. Les rapports que publient les jobs `trivy-fs` et
`package-*` sont filtrés sur HIGH / CRITICAL, exclusions appliquées : collectés
tels quels, ils donneraient `0` en MEDIUM et LOW (non demandés, pas absents) et
`0` constat excepté (Trivy les retire avant d'écrire). Le tableau de bord ne
sait pas distinguer ces deux régimes ; le document `scan` non plus.

**Le zéro des tuiles ne vaut que si des scans existent.** Une somme sur zéro
document vaut zéro : c'est pourquoi la première tuile compte les scans. `3`
signifie que les trois sources ont un dernier scan, et qu'un `0` voisin est
mesuré. Lens ne propose pas mieux : l'option qui affiche `N/A` sur une somme
vide (`emptyAsNull`) affiche aussi `N/A` sur une somme **nulle**, donc sur
« aucun constat CRITICAL ».

**Les panneaux HTTP n'observent pas le back.** `caddy.status` est le journal
d'accès du front, qui répond 200 à tout (SPA). Le back, seul à pouvoir répondre
401 ou 403, ne journalise pas ses accès. Les deux panneaux sont vides par
construction, et leur titre le dit. Ce qui les remplirait : un journal d'accès
côté back, ou `http.response.status_code` dans `traces-apm*`.

**Aucun rapport Dependency-Check réel n'est collecté.** Le collecteur sait le
lire (testé sur une fixture fabriquée), mais aucun rapport réel ne lui a été
passé : la source `dependency-check:back` est absente du tableau de bord.

## `disponibilite.ndjson`

18 objets. Aucune donnée nouvelle : ce tableau de bord relit les logs
(`microcrm-logs*`) et les traces (`traces-apm*`, vue de données `apm-traces-vue`
créée pour lui) sous l'angle « le service répond-il ».

| Panneau                                | Ce qu'il mesure                                                       |
| -------------------------------------- | --------------------------------------------------------------------- |
| Comment lire ce tableau de bord        | texte : ce que la donnée permet et ne permet pas de conclure          |
| Taux de réussite des requêtes du front | `count(caddy.status < 400) / count(caddy.status: *)`                  |
| Requêtes servies par le front          | nombre de lignes du journal d'accès de Caddy                          |
| Démarrages du back                     | nombre de lignes `Started MicroCRMApplication`                        |
| Transactions APM reçues                | documents `processor.event: transaction` de `traces-apm*`             |
| Taux de réussite des transactions APM  | `count(event.outcome: success) / count(event.outcome: *)`             |
| Sondes du kubelet servies par le front | requêtes `kube-probe` par heure, heures vides à zéro, **annoté**      |
| Présence de logs par environnement     | événements par heure, par `kubernetes.namespace`                      |
| Présence de logs par service           | événements par jour, par `kubernetes.container.name`                  |
| Réponses du front par code HTTP        | `caddy.status` dans le temps                                          |
| Démarrages du back, par pod            | lignes de démarrage par jour et par `kubernetes.pod.name`, **annoté** |
| Temps de réponse du front              | p50 / p95 de `caddy.duration`                                         |
| Débit de l'API vu par APM              | transactions par `service.environment`                                |
| Latence de l'API vue par APM           | p50 / p95 de `transaction.duration.us`, `transaction.type: request`   |

**Confrontation à Elasticsearch, 2026-10-02**, fenêtre de 15 jours. Les logs
arrivent en continu : les compteurs bougent entre la requête et la capture, les
rapports non.

| Panneau                       | Kibana                  | Elasticsearch                                      |
| ----------------------------- | ----------------------- | -------------------------------------------------- |
| Taux de réussite du front     | `100.00%`               | 67 842 réponses < 400 sur 67 842                   |
| Requêtes servies par le front | `67,800` puis `68,765`  | 67 842 à l'instant de la requête                   |
| Démarrages du back            | `11`                    | 11 (2, 1, 1, 1, 2, 1, 3 selon les jours)           |
| Présence par environnement    | `microcrm-staging` seul | `terms` sur `kubernetes.namespace` : une seule clé |
| Réponses par code             | `200` seul              | `terms` sur `caddy.status` : 200 seul              |
| Taux de réussite APM          | `99.92%` puis `99.94%`  | 1 572 succès sur 1 573 = 99,94 %                   |

### Ce que cet écran ne dit pas

**Il n'y a pas de mesure de disponibilité, il y a une présence de logs.** Aucune
sonde externe, aucune métrique Kubernetes dans Elasticsearch (pas de Metricbeat,
pas de kube-state-metrics). Le signal le plus dense est la sonde du kubelet sur
le front, journalisée par Caddy. Sur les 360 heures de la fenêtre du relevé, 189
portent au moins une sonde — soit **52,5 %**. ⚠️ Ce chiffre n'est **pas** un
taux de disponibilité : le cluster est un minikube de poste, éteint la nuit, et
un trou dans la courbe ne distingue pas « front arrêté » de « collecte
arrêtée ».

**Les logs de production ne sont pas observés.** Filebeat ne collecte qu'un
namespace (`MICROCRM_NAMESPACE`, voir `filebeat-config.yaml`) : tous les
événements de log viennent de `microcrm-staging`. Le panneau « par
environnement » existe pour que cette absence se voie. Les panneaux APM, eux,
reçoivent les traces de staging et de production.

**Le taux de réussite du front vaut 100 % par construction.** Le front sert une
SPA et répond 200 à tout chemin, et 94 % de ses requêtes sont des sondes. Ce
taux prouve que Caddy répond, rien de plus.

**Les « redémarrages » sont des démarrages.** Elasticsearch ne reçoit pas le
compteur `restartCount` des pods. Ce qui est compté, c'est la ligne
`Started MicroCRMApplication` du back : un pod qui démarre, quelle qu'en soit la
cause — déploiement, relance du cluster, crash. Le front n'a pas d'équivalent.

**Les panneaux APM mêlent trafic réel et essais.** Les transactions portent
`service.environment` : `staging` et `production` pour les pods déployés,
`verification-poste` et `demo-alerting` pour des back lancés sur le poste
(vérification de la chaîne, démonstration des alertes), jusqu'à leur expiration
après dix jours. Le débit se lit donc par environnement. Les transactions des
pods déployés ne viennent que de requêtes provoquées.

## `alertes.ndjson`

8 objets. Ce tableau de bord lit l'index `microcrm-alerts`, dans lequel chaque
règle d'alerte écrit un document par **changement d'état** — `declenchee`, puis
`retablie`. Les règles elles-mêmes, leurs seuils et leur installation sont dans
`../alerting/README.md` ; `MONITORING.md` §11 en donne le raisonnement.

| Panneau                                     | Ce qu'il montre                                                        |
| ------------------------------------------- | ---------------------------------------------------------------------- |
| Comment lire le suivi des alertes           | texte : ce que compte ce tableau, et ce qu'un écran vide ne prouve pas |
| Déclenchements sur la période               | nombre de documents `statut: declenchee`                               |
| Chronologie des déclenchements, par famille | les mêmes, dans le temps, par `famille`                                |
| Déclenchements par famille                  | disponibilité, performance, sécurité                                   |
| Changements d'état par règle                | déclenchements et rétablissements, par `regle_id`                      |
| Journal des alertes                         | table : une ligne par changement d'état, avec valeur et seuil          |

**Relevé du 2026-10-02**, sur une heure, après les essais de déclenchement
(capture `docs/captures/kibana-alertes-suivi-declenchements-2026-10-02.png`) :
8 déclenchements — 4 de disponibilité, 2 de performance, 2 de sécurité — et un
journal de 16 lignes.

### Ce que cet écran ne dit pas

**Un tableau vide ne veut pas dire « tout va bien ».** L'alerting ne se
surveille pas lui-même : si Kibana ou Elasticsearch est arrêté, les règles ne
s'évaluent plus, rien ne s'écrit, et cet écran reste vide exactement comme
lorsqu'aucun seuil n'est franchi.

**Les seize lignes du 2026-10-02 sont des essais.** Chaque règle a été
déclenchée volontairement pour prouver qu'elle sonne ; ce ne sont pas des
incidents. Les trois qui lisent `traces-apm*` l'ont été sur un conteneur lancé
sur le poste, pas sur un pod du cluster.

**Les logs de production n'y figurent pas** : les cinq règles fondées sur les
logs ne voient que `microcrm-staging`. Seules les trois règles sur traces
couvrent la production.

## `dora.ndjson`

13 objets, index `microcrm-dora`, alimenté par `scripts/ci/collect_dora.py`
(`MONITORING.md` §9). Titre : « MicroCRM — métriques DORA (quatre indicateurs,
fenêtre de 30 jours) ».

### Construction

- **Les quatre tuiles lisent la dernière collecte** (`last_value` de `valeur`,
  trié par `@timestamp`), et non `max(valeur)`, qui mélangerait les collectes de
  jours différents.
- **Aucun texte ne cite de chiffre.** Les panneaux de texte expliquent comment
  lire ; les valeurs viennent toutes de l'index, et ne peuvent donc pas périmer.
- **Période par défaut : 30 jours**, la fenêtre du collecteur, pour que les
  tuiles et les compteurs en dessous parlent de la même chose. Sur 90 jours, les
  compteurs remonteraient au-delà de la fenêtre sur laquelle le taux d'échec est
  calculé.
- **La recherche sauvegardée** « Déploiements et rollbacks, un job par ligne »
  inclut les rollbacks, et **la chronologie est annotée** par eux.

### Zéro mesuré et absence de donnée

Deux indicateurs peuvent ne pas avoir de valeur : le délai de mise en
production et le temps de rétablissement, quand rien n'a été mis en production
ou rétabli sur la fenêtre. Une métrique vide s'affiche `0` par défaut, et un
délai de zéro heure se lirait comme la performance parfaite.

Les tuiles respectent la distinction. Vérifié sur la donnée réelle : en
affichant août 2026, où l'index porte `valeur: null` pour ces deux indicateurs,
elles rendent **`N/A`**, tandis que la fréquence rend `0.0000` et le taux
d'échec `100.00 %` (capture
`docs/captures/kibana-dora-non-mesurable-affiche-na-aout-2026-10-02.png`).

⚠️ Cela tient à un détail de construction : la colonne `last_value` est écrite
**sans** le filtre `valeur: *` que l'éditeur Lens ajoute de lui-même. Avec ce
filtre, une collecte à `null` serait ignorée et la tuile afficherait la valeur
d'une collecte plus ancienne. Recréer ces tuiles à la souris réintroduit le
filtre : à vérifier après toute retouche.

### Les valeurs affichées

Injectées le 2026-10-05 à 14 h 39 UTC (`collect_dora.py --days 30
--elasticsearch …`, 67 pipelines, 21 documents), après la release 1.0.1, et
relues dans Kibana sur 30 jours (capture
`docs/captures/kibana-dora-quatre-indicateurs-2026-10-05.png`) :

| Indicateur                   | Tuile     | Ce que ça veut dire                                                                                    |
| ---------------------------- | --------- | ------------------------------------------------------------------------------------------------------ |
| Fréquence de déploiement     | `0.2667`  | 8 déploiements réussis sur 30 jours, sur trois journées                                                |
| Délai de mise en production  | `4.76 h`  | médiane sur 8 observations ; le déclenchement est manuel, l'attente du clic — et d'un week-end — y est |
| Temps de rétablissement      | `2.21 h`  | médiane sur 4 observations                                                                             |
| Taux d'échec des changements | `60.00 %` | 9 échecs sur 15 tentatives, dont 2 comptés comme annulés et 3 tombés sur un cluster arrêté             |

Tuiles « Tentatives » à `15` et « Déploiements réussis » à `8`, 7 échecs tous en
`script_failure`, chronologie sur les 22 et 23 septembre et le 5 octobre.

⚠️ **Le motif `script_failure` ne distingue pas un cluster arrêté d'un
changement défectueux.** Les trois échecs du 2026-10-05 sont des déploiements
tombés sur un minikube arrêté. Le panneau des motifs les range avec les autres,
et le taux d'échec les compte — ce que fait la définition DORA, et ce que ce
tableau ne permet pas de corriger.

⚠️ **Le comptage des rollbacks est volontairement pessimiste.** Un déploiement
réussi puis annulé compte comme un échec, et le rattachement du rollback au
déploiement est purement chronologique : un rollback en échec compte quand même
comme une annulation. C'est assumé et non corrigé (`MONITORING.md` §9.3).

⚠️ **Le texte d'aide en tête du tableau parle de « deux journées »** de
déploiements ; elles sont trois depuis le 2026-10-05. C'est le seul texte du
tableau qui décrive la donnée, et il est à reprendre à la prochaine retouche.
