# Tableaux de bord Kibana — objets sauvegardés

`MONITORING.md` listait à l'origine l'absence de tableau de bord versionné comme
le principal reste du lot ELK. Ce répertoire le comble : **cinq tableaux de
bord**, un fichier chacun — supervision, DORA, sécurité, disponibilité, suivi
des alertes. Le premier, `microcrm.ndjson`, est décrit en tête ; les quatre
autres, ajoutés ou refondus le 2026-10-02, à partir de la section « Les cinq
fichiers, d'un coup d'œil ».

**Le livrable n'est pas un écran dans Kibana, c'est un fichier NDJSON.** Un
tableau de bord construit à la souris vit dans l'index `.kibana` d'un pod ; il
disparaît avec le PVC, avec le namespace, avec le `minikube delete`. Le fichier
versionné ici est la seule forme du tableau de bord qui survive à son instance.

## Importer `microcrm.ndjson`

```shell
kubectl -n logging port-forward svc/kibana 5601:5601

curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
  -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/microcrm.ndjson
```

La réponse doit porter `"success":true` et `"successCount":8`. Un `successCount`
inférieur signale un objet rejeté, pas un import partiel acceptable.

## Réexporter après modification

Modifier le tableau de bord dans Kibana ne modifie pas ce dépôt. Toute retouche
faite à la souris doit être réexportée, sinon elle est perdue au prochain
`minikube delete` — c'est exactement le problème que ce répertoire résout.

```shell
curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_export' \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"objects":[{"type":"dashboard","id":"microcrm-dashboard"}],
       "includeReferencesDeep":true}' \
  -o k8s/elk/dashboards/microcrm.ndjson
```

⚠️ `includeReferencesDeep` n'est pas une option de confort. Sans lui, l'export
ne contient que le tableau de bord : la vue de données `microcrm-logs*` reste
derrière, et la réimportation produit des panneaux vides derrière un message
d'erreur qui ne nomme pas la cause.

## Contenu de `microcrm.ndjson` — 8 objets

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

## Ce que chaque écran ne dit pas

Les descriptions sont portées par les objets eux-mêmes — elles s'affichent sous
l'icône ⓘ de chaque panneau, donc devant celui qui lit le tableau de bord et non
seulement devant celui qui lit ce fichier. Les limites qui changent une
conclusion :

**La latence est celle du front, jamais celle de l'API.** `caddy.duration` est
le temps de service du serveur web qui sert l'application Angular. Le journal
d'accès de Caddy ne voit passer que les fichiers statiques : les appels au back
partent du navigateur vers le service du back et ne traversent jamais le front.
Un p99 à 2 ms ne dit donc rien de la santé de l'API — il dit que Caddy sert vite
des fichiers. Mesurer la latence applicative demande d'instrumenter le back :
c'est écrit depuis le 2026-10-01 (agent OpenTelemetry, `MONITORING.md` §10),
mais les images déployées précèdent l'agent et aucun pod du cluster n'émet de
trace. Les panneaux APM du tableau `disponibilite` montrent des conteneurs
d'essai lancés sur le poste.

**L'écran des erreurs HTTP est vide par construction.** Le front sert une SPA
avec `try_files … /index.html` : tout chemin inconnu renvoie 200 avec la page,
et c'est Angular qui décide ensuite qu'il n'y a rien à cette adresse. Un 404 ne
peut donc pas apparaître dans les logs de Caddy. Le zéro affiché est le
comportement attendu du routage, pas une preuve d'absence d'erreur — d'où le
titre du panneau, qui le dit plutôt que de laisser conclure. Les erreurs
observables sont celles du back, panneau voisin.

**Le volume compte des lignes de log, pas des requêtes.** Une requête peut
n'en produire aucune, un démarrage en produit cinquante.

**Les erreurs du back ne couvrent que les lignes encodées en ECS.** La bannière
ASCII de Spring Boot et les quelques lignes émises avant l'initialisation de
Logback n'ont pas de champ `log.level` : elles sont invisibles à ce panneau. Sur
355 documents, 54 portent un `log.level`.

**Le front n'a pas de `log.level`, et son `message` reste le JSON brut.** Son
journal est décodé sous le préfixe `caddy` (`MONITORING.md` §4), précisément
pour ne pas entrer en collision avec l'espace ECS : ses champs exploitables sont
donc `caddy.status`, `caddy.duration`, `caddy.request.uri`, jamais `log.level`.
La colonne `message` de la table affiche la ligne d'origine, non réécrite — un
tiret dans la colonne `log.level` signale une ligne du front, pas une anomalie.

## Deux pièges de construction, réglés ici

**`caddy.duration` est en secondes.** Affiché tel quel, le p50 vaut `0.00043` —
un axe illisible. La conversion n'est pas faite dans les visualisations mais
**une seule fois, dans le `fieldFormatMap` de la vue de données** : le champ est
déclaré `inputFormat: seconds` / `outputFormat: asMilliseconds`. Tout panneau
qui touche ce champ hérite de l'unité, y compris ceux qui n'existent pas encore.
C'est aussi pourquoi la vue de données doit impérativement faire partie de
l'export : sans elle, l'unité est perdue en même temps que le reste.

**`log.level` est une clé plate qui cohabite avec un objet `log` imbriqué.**
Le `_source` d'un document du back contient à la fois `"log.level": "INFO"` et
`"log": {"file": {"path": …}}`. Elasticsearch les fusionne au mapping et Kibana
les résout par l'API `fields`, donc filtrage et affichage fonctionnent — vérifié
plutôt que supposé : `log.level: *` renvoie 54 documents dans Kibana, soit
exactement les 52 `INFO` + 2 `WARN` comptés par une agrégation `terms` sur
Elasticsearch. Le pipeline d'ingestion évoqué en `MONITORING.md` §12 reste
souhaitable pour la propreté, mais il n'est pas nécessaire à ces écrans.

## Limites de l'ensemble

La fenêtre par défaut est `now-24h` et elle est **restaurée à l'ouverture**
(`timeRestore`), pour que le tableau de bord montre des données dès l'import
plutôt qu'un écran vide sur une plage de 15 minutes.

**Ces écrans se regardent ; ce ne sont pas eux qui préviennent.** Cette phrase
se terminait jusqu'au 2026-10-02 par « aucune alerte ». Huit règles d'alerte
existent désormais, à côté de ce répertoire (`../alerting/`), et elles lisent
les mêmes index que ces tableaux de bord. Ce qu'elles écrivent se consulte dans
`alertes.ndjson`, décrit plus bas — et se **consulte** seulement : aucune
notification ne sort de Kibana (`MONITORING.md` §11.5).

Aucune rétention non plus — sans ILM, l'historique s'arrête là où le PVC se
remplit.

## Les cinq fichiers, d'un coup d'œil

| Fichier                | Tableau de bord           | Objets | Données lues                                           |
| ---------------------- | ------------------------- | ------ | ------------------------------------------------------ |
| `microcrm.ndjson`      | `microcrm-dashboard`      | 8      | `microcrm-logs*`                                       |
| `dora.ndjson`          | `dora-dashboard`          | 13     | `microcrm-dora`                                        |
| `securite.ndjson`      | `securite-dashboard`      | 22     | `microcrm-security`, `microcrm-logs*`, `microcrm-dora` |
| `disponibilite.ndjson` | `disponibilite-dashboard` | 18     | `microcrm-logs*`, `traces-apm*`, `microcrm-dora`       |
| `alertes.ndjson`       | `alertes-dashboard`       | 8      | `microcrm-alerts`                                      |

Les cinq s'importent de la même façon, et chacun embarque les vues de données
dont il dépend — y compris celles d'un autre fichier quand il y puise ses
annotations. L'ordre d'import n'a donc pas d'importance.

```shell
kubectl -n logging port-forward svc/kibana 5601:5601
for f in microcrm dora securite disponibilite alertes; do
  curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
    -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/$f.ndjson
done
```

Vérifié le 2026-10-02 sur Kibana 8.19.7, **à froid** : les 49 objets de
`dora`, `securite` et `disponibilite` ont d'abord été supprimés de l'instance
(il ne restait que `microcrm-dashboard`), puis les trois fichiers réimportés.

| Fichier                | Réponse de l'import                                  |
| ---------------------- | ---------------------------------------------------- |
| `securite.ndjson`      | `"success": true, "successCount": 22`, aucune erreur |
| `disponibilite.ndjson` | `"success": true, "successCount": 18`, aucune erreur |
| `dora.ndjson`          | `"success": true, "successCount": 13`, aucune erreur |

`alertes.ndjson` a été contrôlé séparément, le même jour et de la même façon —
objets supprimés, puis réimport : `"success": true, "successCount": 8`.

Pour réexporter l'un d'eux après retouche, la commande de la section
« Réexporter après modification » vaut pour tous : remplacer l'identifiant du
tableau de bord et le nom du fichier.

### Les annotations

Trois graphiques portent des **annotations Lens par requête** : des marqueurs
verticaux calculés à l'affichage, pas dessinés à la main. Elles lisent toutes
l'index `microcrm-dora` (les jobs de déploiement et de rollback relevés par
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
`--elasticsearch` après un déploiement, sinon le marqueur manque — et son
absence ne veut pas dire « pas de déploiement ».

⚠️ Piège rencontré en les construisant : les champs affichés dans l'infobulle
d'une annotation (`extraFields`) doivent être **agrégeables**. `job` est un
champ `text` dans `microcrm-dora` (mapping dynamique) : le citer tel quel fait
échouer tout le panneau sur `Tooltip fields job not found in data view`. C'est
`job.keyword` qu'il faut nommer.

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

Confronté à Elasticsearch le 2026-10-02 (agrégations équivalentes, fenêtre de
90 jours) — chaque valeur est celle que le panneau affiche :

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

Les cinq constats HIGH sont cinq CVE de `jackson-core` / `jackson-databind`
2.21.4 dans l'image `back:5bf1d6a2`. Le correctif est sur la branche
(`fix/jackson-databind-cve`, Jackson 2.21.7) mais **aucune image n'a encore été
construite depuis** : le tableau de bord montre l'image publiée, pas le code.

### Ce que cet écran ne dit pas

**L'historique a été rejoué, il n'a pas été vécu.** Aucun scan n'avait jamais
été collecté avant le 2026-10-02. Pour qu'une courbe existe, huit commits
(du 2026-08-01 au 2026-10-02) ont été exportés par `git archive` et scannés
avec Trivy 0.69.3, ainsi que les images du registry portant leur tag quand elles
existent (`50a07951`, `34df46de`, `234ab50a`, `5bf1d6a2`). Chaque scan est daté
du commit, mais jugé avec la base de vulnérabilités **du 2026-10-02**. La courbe
dit donc « ce que ces versions contiennent de vulnérable au regard de ce qu'on
sait aujourd'hui », pas « ce que le pipeline voyait ce jour-là ». Les exceptions
appliquées à chaque point sont celles du `.trivyignore.yaml` **de ce commit**.

**Les rapports rejoués sont plus larges que ceux de la CI.** Ils ont été
produits sans filtre de sévérité et sans `--ignorefile`, pour que MEDIUM, LOW et
constats exceptés apparaissent. Les rapports que publient les jobs `trivy-fs` et
`package-*` sont filtrés sur HIGH / CRITICAL, exclusions appliquées : collectés
tels quels, ils donneront `0` en MEDIUM et LOW (non demandés, pas absents) et
`0` constat excepté (Trivy les retire avant d'écrire). Le tableau de bord ne
sait pas distinguer ces deux régimes ; le document `scan` non plus.

**Le zéro des tuiles ne vaut que si des scans existent.** Une somme sur zéro
document vaut zéro : c'est pourquoi la première tuile compte les scans. `3`
signifie que les trois sources ont un dernier scan, et qu'un `0` voisin est
mesuré. Lens ne propose pas mieux : l'option qui affiche `N/A` sur une somme
vide (`emptyAsNull`) affiche aussi `N/A` sur une somme **nulle**, donc sur
« aucun constat CRITICAL » — vérifié, c'est le premier rendu obtenu.

**Les panneaux HTTP n'observent pas le back.** `caddy.status` est le journal
d'accès du front, qui répond 200 à tout (SPA). Le back, seul à pouvoir répondre
401 ou 403, ne journalise pas ses accès. Les deux panneaux sont vides par
construction, et leur titre le dit. Ce qui les remplirait : un journal d'accès
côté back, ou `http.response.status_code` dans `traces-apm*` une fois les images
instrumentées déployées.

**Aucun rapport Dependency-Check réel n'a été collecté.** Le collecteur sait le
lire (testé sur une fixture fabriquée), mais le rapport JSON n'existait pas sur
le poste : la source `dependency-check:back` est absente du tableau de bord.

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

Confronté à Elasticsearch le 2026-10-02 vers 21 h 45, fenêtre de 15 jours. Les
logs et les traces arrivent en continu : les compteurs bougent entre la requête
et la capture, les rapports non.

| Panneau                       | Kibana                  | Elasticsearch                                      |
| ----------------------------- | ----------------------- | -------------------------------------------------- |
| Taux de réussite du front     | `100.00%`               | 67 842 réponses < 400 sur 67 842                   |
| Requêtes servies par le front | `67,800` puis `68,765`  | 67 842 à l'instant de la requête                   |
| Démarrages du back            | `11`                    | 11 (2, 1, 1, 1, 2, 1, 3 selon les jours)           |
| Présence par environnement    | `microcrm-staging` seul | `terms` sur `kubernetes.namespace` : une seule clé |
| Réponses par code             | `200` seul              | `terms` sur `caddy.status` : 200 seul              |
| Taux de réussite APM          | `99.92%` puis `99.94%`  | 1 572 succès sur 1 573 = 99,94 %                   |
| Débit APM                     | deux environnements     | `demo-alerting` 1 248, `verification-poste` 325    |

### Ce que cet écran ne dit pas

**Il n'y a pas de mesure de disponibilité, il y a une présence de logs.** Aucune
sonde externe, aucune métrique Kubernetes dans Elasticsearch (pas de Metricbeat,
pas de kube-state-metrics). Le signal le plus dense est la sonde du kubelet sur
le front, journalisée par Caddy. Sur les 360 heures de la fenêtre, 189 portent
au moins une sonde — soit **52,5 %**. ⚠️ Ce chiffre n'est **pas** un taux de
disponibilité : le cluster est un minikube de poste, éteint la nuit, et un trou
dans la courbe ne distingue pas « front arrêté » de « collecte arrêtée ».

**La production n'est pas observée.** Filebeat ne collecte qu'un namespace
(`MICROCRM_NAMESPACE`, voir `filebeat-config.yaml`) : les 68 000 événements de
la fenêtre viennent tous de `microcrm-staging`. Le panneau « par environnement »
existe pour que cette absence se voie.

**Le taux de réussite du front vaut 100 % par construction.** Le front sert une
SPA et répond 200 à tout chemin, et 94 % de ses requêtes sont des sondes. Ce
taux prouve que Caddy répond, rien de plus.

**Les « redémarrages » sont des démarrages.** Elasticsearch ne reçoit pas le
compteur `restartCount` des pods. Ce qui est compté, c'est la ligne
`Started MicroCRMApplication` du back : un pod qui démarre, quelle qu'en soit la
cause — déploiement, relance du cluster, crash. Le front n'a pas d'équivalent.

**Les panneaux APM ne décrivent pas l'application déployée.** Les pods de
staging (`back:bf272532`) et de production (`back:9f4168b3`) tournent sur des
images antérieures à l'instrumentation OpenTelemetry. Les transactions de
`traces-apm*` portent `service.environment: verification-poste` ou
`demo-alerting` : des back lancés pour vérifier la chaîne de traces et pour
démontrer les alertes. Débit et latence sont donc ceux de ces essais. Les
panneaux sont en place pour le jour où une image instrumentée sera déployée —
ils se rempliront sans retouche.

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

Relevé le 2026-10-02, sur une heure, après les essais de déclenchement
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
incidents. Trois d'entre elles — celles qui lisent `traces-apm*` — l'ont été sur
un conteneur lancé sur le poste, pas sur un pod du cluster.

**La production n'y figurera pas** tant que Filebeat ne collecte que
`microcrm-staging` et qu'aucun back déployé n'émet de trace.

## `dora.ndjson`

13 objets, index `microcrm-dora`, alimenté par `scripts/ci/collect_dora.py`.

### ⚠️ Ce que ces écrans affichent, et qu'il faut lire avant de conclure

**La chaîne déploie depuis le 2026-09-22**, après sept échecs et deux mois de
quota épuisé. Les quatre indicateurs ont donc une valeur, et celle du taux
d'échec n'est pas flatteuse — ce qui est le sujet : ces chiffres disent ce que
le projet a fait, pas ce qu'on voudrait montrer.

Réinjecté le 2026-10-02 (`collect_dora.py --days 30 --elasticsearch …`,
57 pipelines, 15 documents indexés) et relu dans Kibana :

| Indicateur                   | Tuile     | Ce que ça veut dire                                                               |
| ---------------------------- | --------- | --------------------------------------------------------------------------------- |
| Fréquence de déploiement     | `0.1667`  | 5 déploiements réussis sur 30 jours, tous sur deux journées consécutives          |
| Délai de mise en production  | `1.38 h`  | médiane sur 5 observations ; le déclenchement est manuel, l'attente du clic y est |
| Temps de rétablissement      | `2.14 h`  | médiane sur 2 observations seulement                                              |
| Taux d'échec des changements | `66.67 %` | 6 échecs sur 9 tentatives, dont 2 comptés comme annulés par un rollback           |

Confronté à Elasticsearch le même jour : `top_metrics` sur `valeur` trié par
`@timestamp` rend 0,1667 / 1,38 / 2,14 / 66,67 ; 9 jobs de déploiement sur
30 jours (5 `success`, 4 `failed`, tous `script_failure`) et 2 rollbacks — ce
qu'affichent les tuiles « Tentatives » (`9`) et « Déploiements réussis » (`5`),
le panneau des motifs et la chronologie.

⚠️ **Le comptage des rollbacks est volontairement pessimiste.** Un déploiement
réussi puis annulé compte comme un échec, et le rattachement du rollback au
déploiement est purement chronologique : le rollback du 2026-09-23 à 13:01:30 a
échoué sur un timeout, n'a donc rien annulé, et compte quand même comme une
annulation. C'est assumé et non corrigé ; le détail est dans `MONITORING.md`.

### Ce qui a changé le 2026-10-02

Le tableau de bord avait été construit le 2026-08-16, quand rien n'avait jamais
été déployé, et il le disait partout : dans son titre (« aucun déploiement
réussi »), dans le texte d'en-tête (« sept déploiements, sept échecs »), dans
les sous-titres des tuiles, et surtout dans deux panneaux de texte qui
écrivaient « Non mesurable » en dur. Après le 2026-09-22, ces deux panneaux
affirmaient donc le contraire de l'index qu'ils étaient censés résumer. Et
l'index lui-même n'avait pas été réalimenté depuis le 2026-08-16.

- **Titre** : « MicroCRM — métriques DORA (quatre indicateurs, fenêtre de
  30 jours) ». La recherche sauvegardée s'intitule « Déploiements et rollbacks,
  un job par ligne » et inclut désormais les rollbacks.
- **Les quatre tuiles lisent la dernière collecte** (`last_value` de `valeur`,
  trié par `@timestamp`) au lieu de `max(valeur)`, qui aurait mélangé les
  collectes de jours différents. Les textes ne citent plus aucun chiffre : ils
  ne peuvent plus périmer.
- **Période par défaut : 30 jours**, la fenêtre du collecteur, pour que les
  tuiles et les compteurs en dessous parlent de la même chose. Sur 90 jours, les
  compteurs remontent à 16 tentatives quand le taux d'échec en annonce 9.
- **La chronologie est annotée** par les rollbacks.

### Zéro mesuré et absence de donnée, sans panneau de texte

Les deux indicateurs qui peuvent ne pas avoir de valeur étaient rendus en texte,
parce qu'une métrique vide s'affiche `0` et qu'un délai de mise en production de
zéro heure se lit comme la performance parfaite. Le texte réglait ce cas et en
créait un pire : il ne suivait pas la donnée.

Ce sont maintenant des tuiles, et la distinction tient toujours — vérifié sur
la donnée réelle plutôt que supposé. En affichant le mois d'août 2026, où
l'index porte `valeur: null` pour ces deux indicateurs, les tuiles rendent
**`N/A`**, tandis que la fréquence rend `0.0000` et le taux d'échec `100.00 %`
(capture `docs/captures/kibana-dora-non-mesurable-affiche-na-aout-2026-10-02.png`).

⚠️ Cela ne tient qu'à un détail de construction : la colonne `last_value` est
écrite **sans** le filtre `valeur: *` que l'éditeur Lens ajoute de lui-même.
Avec ce filtre, une collecte à `null` serait ignorée et la tuile afficherait la
valeur d'une collecte plus ancienne. Recréer ces tuiles à la souris réintroduit
le filtre : c'est à vérifier après toute retouche.

### Régénérer après modification

Modifier dans Kibana, puis exporter. **Ne pas retoucher un objet à la main dans
le NDJSON** : un objet sans `typeMigrationVersion` fait échouer l'import sur
`Cannot read properties of undefined (reading 'layers')`.

```shell
curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_export' \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"objects":[{"type":"dashboard","id":"dora-dashboard"}],"includeReferencesDeep":true}' \
  > k8s/elk/dashboards/dora.ndjson
```

`alertes.ndjson` est lui aussi un export de Kibana. Les trois autres fichiers
du 2026-10-02 — `dora`, `securite`, `disponibilite` — n'ont pas été dessinés à
la souris : leurs
objets ont été décrits par un script, importés par l'API, contrôlés à l'écran,
puis **exportés par Kibana** — ce sont ces exports qui sont versionnés, pas la
sortie du script. C'est ce qui garantit que chaque objet porte les champs de
migration que Kibana attend.
