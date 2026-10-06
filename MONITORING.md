# Supervision — la stack ELK, les traces et l'alerting

Supervision de MicroCRM sur le cluster local, en trois volets :

- **les logs** : Filebeat, Elasticsearch et Kibana (8.19.7) centralisent les
  logs des pods de staging ;
- **les traces de l'API** : un agent OpenTelemetry dans le back envoie ses
  traces à APM Server, dans la même stack, depuis staging et production ;
- **l'alerting** : huit règles Kibana versionnées, qui écrivent dans un index et
  dans le journal de Kibana, sans notification hors de Kibana.

S'y ajoutent cinq tableaux de bord versionnés et le calcul des indicateurs DORA.
Ce document dit comment la chaîne fonctionne, pourquoi elle est construite
ainsi, comment la rejouer, et ce qu'elle ne fait pas.

**Preuves de fonctionnement**

| Date       | Ce qui a été vérifié                             | Résultat                                                                                                                 |
| ---------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| 2026-08-16 | Mise en service des logs                         | Elasticsearch, Kibana et Filebeat `Running` ; champs ECS et métadonnées Kubernetes décodés ; 100 % `microcrm-staging`    |
| 2026-10-02 | Collecte des logs                                | 92 175 documents `microcrm-logs-*`, tous de `microcrm-staging` ; pods du namespace `logging` `1/1`                       |
| 2026-10-02 | Traces, conteneur lancé sur le poste             | 325 transactions et 1 211 spans ; latence par route mesurée (§10.4)                                                      |
| 2026-10-02 | Déclenchement volontaire des 8 règles d'alerte   | 8 déclenchements, 8 rétablissements, 16 documents dans `microcrm-alerts` (§11.3)                                         |
| 2026-10-02 | Réimport à froid des tableaux de bord            | 69 objets en 5 fichiers, `successCount` 8, 13, 22, 18 et 8 (§8) ; `microcrm.ndjson` vérifié à la mise en service         |
| 2026-10-05 | Traces venues du cluster, après la release 1.0.1 | 534 documents `staging` en 15 min, puis 187 `production` et 180 `staging` en 10 min ; logs du back portant un `trace.id` |
| 2026-10-05 | Indicateurs DORA recalculés et injectés          | 67 pipelines, 21 documents dans `microcrm-dora` (§9.1)                                                                   |

## 1. Ce que ça couvre

Les contrôles du pipeline agissent tous **avant** le déploiement
([QUALITY.md](QUALITY.md) §6). Sans supervision, la seule façon de lire un log
serait `kubectl logs`, un pod à la fois, sans historique : un pod redémarré
emporterait ses logs avec lui.

Trois besoins, trois réponses :

| Besoin                             | Réponse                                                | Section |
| ---------------------------------- | ------------------------------------------------------ | ------- |
| Lire et filtrer ce que dit l'appli | logs JSON ECS collectés par Filebeat, lus dans Kibana  | §2 à §8 |
| Mesurer la latence de l'API        | traces OpenTelemetry vers Elastic APM                  | §10     |
| Être prévenu d'un écart            | règles d'alerte Kibana, consignées dans un index dédié | §11     |

Ce qui reste hors de portée : le CPU et la mémoire des pods, que rien ne mesure
(§12), et toute notification hors de Kibana (§11.5).

## 2. La chaîne, maillon par maillon

```
pod back ─┐                                    ┌─ Elasticsearch ─ Kibana
          ├─ stdout ─ /var/log/containers ─ Filebeat ─┘
pod front ┘            (sur le nœud)
```

1. **Le back écrit du JSON au format ECS** — pas du texte. Sans cela,
   Elasticsearch reçoit une chaîne opaque et Kibana ne sait rien filtrer.
2. **Filebeat**, en DaemonSet, lit les fichiers de log du nœud, décode le JSON,
   et ajoute les métadonnées Kubernetes (pod, namespace, image).
3. **Elasticsearch** indexe dans un _data stream_ dédié au projet.
4. **Kibana** lit Elasticsearch.

Le chemin des traces, du pod `back` à APM Server, a sa propre section (§10) et
son propre schéma.

## 3. Les logs applicatifs : deux formats, un profil

Le _structured logging_ natif de Spring Boot n'existe qu'à partir de la 3.4 ; le
projet est en 3.2.5. La sortie JSON passe donc par un encodeur Logback,
`co.elastic.logging:logback-ecs-encoder:1.7.0`, choisi plutôt que l'encodeur
Logstash parce qu'il émet directement le schéma qu'attendent Elasticsearch et
Kibana ; l'autre imposerait de renommer chaque champ, donc de maintenir une
traduction en double.

`back/src/main/resources/logback-spring.xml` rend **deux** formats :

| Contexte               | Format   | Pourquoi                                             |
| ---------------------- | -------- | ---------------------------------------------------- |
| Poste de développement | texte    | du JSON sur une console est illisible pour un humain |
| Conteneur              | JSON ECS | c'est ce que la chaîne sait exploiter                |

La bascule se fait par le profil Spring `container`, posé par la clé
`SPRING_PROFILES_ACTIVE` de la ConfigMap `microcrm-config`.

⚠️ **Sans cette clé, le pod journalise en texte sans que rien ne le signale**, et
Filebeat déverse dans Elasticsearch des lignes que Kibana ne sait pas filtrer.
Le défaut lisible-par-l'humain est délibéré côté application ; c'est donc la
ConfigMap, et elle seule, qui décide. Elle existe en **deux exemplaires** —
`k8s/base/configmap.yaml` et `helm/microcrm/templates/configmap.yaml` — et
l'assertion d'équivalence de `scripts/tests/validate_k8s.sh` échoue en nommant
le champ si l'un des deux est oublié.

## 4. Filebeat ne collecte pas tout, et c'est délibéré

**Ce cluster n'est pas dédié à MicroCRM.** Il héberge aussi les namespaces `dev`
et `staging` d'autres projets (`olympic-games-app`, `workshop-organizer`) et des
pods dans `default`. Un Filebeat non filtré y ingérerait les logs de projets
tiers : ce n'est pas une question de volume, c'est une question de périmètre.

L'autodiscover ne collecte donc que le namespace de l'application, et ce
namespace est une valeur de configuration (`MICROCRM_NAMESPACE` dans
`k8s/elk/elk-config.yaml`, valeur `microcrm-staging`), pas une chaîne enfouie
dans le YAML. Un second filtre, sur `kubernetes.namespace`, double le premier.
Vérifié : 100 % des documents indexés viennent de `microcrm-staging`.
Conséquence assumée : **la production n'est pas dans les logs** (§12).

**Deux décodages JSON, et un seul à la racine.** Le back produit de l'ECS, décodé
à la racine. Le front (Caddy) écrit lui aussi du JSON, mais **non-ECS**, dont les
champs portent les mêmes noms que ceux de Filebeat sans avoir la même forme. Un
décodage appliqué à tous les conteneurs fait rejeter ses documents :

```
document_parsing_exception: object mapping for [file] tried to parse field [file] as object
```

Une collision de mapping est **irréversible** : une fois le champ typé dans
l'index, aucun document contradictoire n'y entre plus. Le journal du front est
donc décodé sous le préfixe `caddy`, ce qui isole ses champs de l'espace ECS et
laisse les deux formats cohabiter.

## 5. La latence du front : le journal d'accès de Caddy

Les logs applicatifs du back portent ce que l'application raconte, pas le temps
qu'elle met. La seule source qui voit passer le trafic du front est le journal
d'accès de Caddy, activé par la directive `log` de `front/Caddyfile`. Il porte
les trois mesures d'un coup : `caddy.status`, `caddy.duration` et le simple
comptage.

Mesuré sur 105 requêtes :

```
p50 = 0,14 ms     p95 = 1,60 ms     p99 = 3,11 ms
```

⚠️ **C'est la latence vue par le serveur web, pas par l'API.** Caddy sert le
bundle Angular et `/config.json` ; les appels à l'API partent du navigateur vers
un hôte distinct et ne passent pas par lui. La latence de l'API est mesurée par
les traces (§10). Les deux mesures ne se remplacent pas — celle-ci reste la
seule qui voie le front.

⚠️ **Le front ne produit quasiment jamais de 4xx.** C'est une application
Angular servie avec `try_files {path} /index.html` : tout chemin inconnu renvoie
`200` avec la page, à charge pour le routeur Angular de décider. Vérifié — 12
requêtes vers des chemins inexistants ont toutes renvoyé `200`. Les erreurs
réelles se lisent donc côté back, dans `log.level`.

## 6. Le dimensionnement, et pourquoi il tient

Une stack ELK sous-dimensionnée ne démarre pas. Les chiffres, et la règle qui
les gouverne :

| Composant     | requests      | limits         | tas                    |
| ------------- | ------------- | -------------- | ---------------------- |
| Elasticsearch | 500m / 1536Mi | 2 CPU / 2Gi    | 1 Gio (`ES_JAVA_OPTS`) |
| Kibana        | 200m / 768Mi  | 1 CPU / 1536Mi | 768 Mio                |
| Filebeat      | 100m / 128Mi  | 500m / 256Mi   | —                      |
| APM Server    | 50m / 64Mi    | 500m / 256Mi   | —                      |

**La limite mémoire vaut le double du tas.** Un conteneur JVM dont la limite
égale le tas est tué par l'OOM killer au premier pic hors-tas — metaspace, cache
de code, piles de threads. C'est la cause la plus banale d'une stack ELK qui
« ne démarre pas » sans message utile.

Le namespace porte un `ResourceQuota` créé par Terraform
(`terraform/environments/logging/`), calé sur le **pic d'un déploiement** et non
sur l'état stable. Le calcul du pic diffère de celui des environnements
applicatifs, parce que les composants n'ont pas la même stratégie :

- **Elasticsearch est en `Recreate`**, pas en `RollingUpdate`. Son PVC est
  `ReadWriteOnce` et son répertoire de données verrouillé par `node.lock` : un
  second pod resterait bloqué en `ContainerCreating`, pendant que l'ancien reste
  en place — un déploiement qui ne finit jamais. Son pic vaut donc **1 pod**.
- Kibana et APM Server surgent à 2. Filebeat est un DaemonSet : il remplace sans
  ajouter.

Vérifié en relançant Kibana et en observant le quota pendant le rollout :

```
$ kubectl -n logging describe quota logging-quota      # pendant le rollout
limits.memory    5376Mi  6Gi
requests.memory  3200Mi  4Gi
pods             4       12
```

Ce sont exactement les valeurs calculées dans `terraform.tfvars`, au mégaoctet
près. Au pic d'un double rollout Kibana + APM Server, le 2026-09-29, le quota
affichait `limits.memory 5888Mi/6Gi` : **la marge restante est de 256 Mio**, et
le prochain composant ajouté à `logging` devra relever le quota.

## 7. Les pièges écartés

Ils sont documentés parce qu'ils se reproduiront.

**`vm.max_map_count`.** Elasticsearch exige 262144 et refuse de démarrer sinon.
La parade habituelle est un initContainer **privilégié** — inacceptable ici, le
projet impose `runAsNonRoot` et `allowPrivilegeEscalation: false` partout, et
`validate_k8s.sh` le vérifie. La stack utilise `node.store.allow_mmap: false` :
accès disque moins efficace, mais aucun conteneur privilégié dans un cluster
partagé avec d'autres projets.

**Filebeat doit lire des fichiers appartenant à root.** Les journaux sont en
`0640 root:root` derrière des répertoires `0710`. Plutôt qu'un conteneur
privilégié ou un UID root, Filebeat tourne en `runAsUser: 1000` avec
`runAsGroup: 0` : le groupe root donne exactement le droit de lecture requis,
sans UID root, sans capability ajoutée, et tous les montages hôte sont en
`readOnly`.

**Elasticsearch ne peut pas tourner en `readOnlyRootFilesystem`.** Son point
d'entrée crée `config/elasticsearch.keystore` et écrit sous `logs/`, dans la même
arborescence que `jvm.options` et `modules` — y monter des `emptyDir` empêche le
démarrage. C'est la seule exception au socle de sécurité du projet ; Kibana et
Filebeat restent en `true`.

**En 8.x, Filebeat écrit dans des _data streams_**, pas dans des index. D'où le
nom `.ds-microcrm-logs-…` dans `_cat/indices`, et `setup.ilm.enabled: false`
comme contrepartie d'un nommage propre au projet.

## 8. Les tableaux de bord, et pourquoi ils sont dans le dépôt

**Cinq tableaux de bord**, un fichier NDJSON chacun dans `k8s/elk/dashboards/`.

| Fichier                | Ce qu'il montre                                                                                           | Objets | Données lues                                           |
| ---------------------- | --------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------ |
| `microcrm.ndjson`      | Supervision : volume par conteneur, latence du front, erreurs applicatives et HTTP, statuts, logs récents | 8      | `microcrm-logs*`                                       |
| `dora.ndjson`          | Les quatre indicateurs DORA, les tentatives, les motifs d'échec, la chronologie (§9)                      | 13     | `microcrm-dora`                                        |
| `securite.ndjson`      | Constats Trivy par sévérité, par cible et dans le temps ; exceptions et leur échéance ; erreurs du back   | 22     | `microcrm-security`, `microcrm-logs*`, `microcrm-dora` |
| `disponibilite.ndjson` | Sondes servies par le front, démarrages du back, présence de logs, débit et latence vus par APM           | 18     | `microcrm-logs*`, `traces-apm*`, `microcrm-dora`       |
| `alertes.ndjson`       | Suivi des alertes : déclenchements par famille et par règle, journal des changements d'état (§11)         | 8      | `microcrm-alerts`                                      |

Le détail panneau par panneau, et la confrontation de chaque valeur affichée à
l'agrégation Elasticsearch équivalente, sont dans
`k8s/elk/dashboards/README.md`. Trois points à connaître avant de les lire :

- **Le tableau de sécurité est alimenté par `scripts/ci/collect_security.py`**
  (`SCRIPTS.md`), qui transforme les rapports JSON de Trivy et de
  Dependency-Check en documents de l'index `microcrm-security`. Son historique
  est **rejoué** : huit commits scannés le 2026-10-02 avec la base de
  vulnérabilités du jour, datés du commit. Aucun job ne passe au collecteur les
  rapports publiés par `trivy-fs`, `package-*` et `dependency-check-back` :
  l'index reflète le 2026-10-02.
- **Le tableau de disponibilité ne mesure pas une disponibilité.** Il montre une
  présence de logs, en staging seulement, sur un minikube éteint la nuit : 189
  heures sur 360 portent au moins une sonde, et ce n'est pas un taux de service.
- **Le tableau DORA** s'intitule « MicroCRM — métriques DORA (quatre
  indicateurs, fenêtre de 30 jours) ». Ses indicateurs sont des tuiles qui
  lisent la dernière collecte, et sa période par défaut est de 30 jours — la
  fenêtre du collecteur. Aucun texte n'y cite de chiffre écrit en dur : rien ne
  peut y contredire l'index.

**Le livrable n'est pas « des écrans dans Kibana », c'est un fichier.** Un
tableau de bord qui n'existe que dans une instance disparaît avec elle — et
celle-ci tourne sur un minikube de poste de développement. Les objets
sauvegardés sont donc exportés en NDJSON, vues de données comprises : un export
qui les oublierait produirait à la réimportation des panneaux vides et un
message obscur.

Vérifié **à froid**, objets supprimés de l'instance avant l'import pour que le
test ne soit pas un simple écrasement : `successCount` 8, 22, 18, 13 et 8, aucune
erreur. Chaque panneau a été confronté à la même agrégation jouée directement
contre Elasticsearch : mêmes chiffres des deux côtés, y compris la latence après
conversion des secondes en millisecondes.

⚠️ **L'unité de `caddy.duration` est déclarée dans la vue de données**
(`fieldFormatMap`, secondes → millisecondes), pas dans une formule de chaque
panneau. Un panneau ajouté en hérite ; c'est aussi ce qui rend la vue de données
indispensable à l'export.

⚠️ **Un NDJSON écrit à la main ne s'importe pas.** Sans `typeMigrationVersion`,
Kibana rejoue toute la chaîne de migration 7.x → 8.x et échoue sur
`Cannot read properties of undefined (reading 'layers')`. Les objets sont créés
par l'API ou dans l'interface, contrôlés à l'écran, puis exportés par Kibana —
jamais rédigés à la main. La commande de régénération est dans
`k8s/elk/dashboards/README.md`.

## 9. Les métriques DORA

Les quatre indicateurs DORA sont calculés par `scripts/ci/collect_dora.py`, en
Python standard et sans aucune dépendance — même règle que le reste de
`scripts/ci/`, parce que le job tourne dans une image qui n'a pas `pip install`.

**Pourquoi un collecteur maison.** Les métriques DORA natives de GitLab sont
réservées aux offres payantes. Sur le Free Tier, il faut les calculer soi-même
depuis l'API — et le projet est mesurable sans jeton : le dépôt GitHub se
miroite vers un projet GitLab **public**, où le pipeline tourne réellement.

### 9.1 Les valeurs de référence et les valeurs actuelles

Valeur de référence : la mesure du 2026-09-23 (50 pipelines), au lendemain des
premiers déploiements réussis. Valeur actuelle : recalculée le 2026-10-05 à
14 h 39 UTC, après le dernier déploiement de la release 1.0.1, sur les
**67 pipelines** des 30 derniers jours, puis injectée dans `microcrm-dora`
(21 documents).

| Indicateur                            | Référence (2026-09-23)       | Actuel (2026-10-05)               | Observations |
| ------------------------------------- | ---------------------------- | --------------------------------- | ------------ |
| Fréquence de déploiement              | 0,1667 par jour              | **0,2667** par jour               | 5 → 8        |
| Délai de mise en production (médiane) | 1,38 h (min 0,64 / max 4,87) | **4,76 h** (min 0,64 / max 40,88) | 5 → 8        |
| Temps de rétablissement (médiane)     | 2,14 h (min 0,09 / max 4,18) | **2,21 h** (min 0,09 / max 4,18)  | 2 → 4        |
| Taux d'échec des changements          | 66,67 % (6 sur 9)            | **60 %** (9 sur 15)               | 9 → 15       |

Sur la fenêtre, quinze jobs de déploiement ont réellement tourné, huit ont
réussi, et deux rollbacks ont été joués. Staging et production tournent avec
des images du registry GitLab, posées par la CI ; la production en `1.0.1`. Les
jobs de déploiement tournent sur un runner auto-hébergé et atteignent le
cluster par le tunnel de l'agent GitLab ([TERRAFORM.md](TERRAFORM.md) §4.1) ;
le garde-fou `exige_namespace` fait échouer un job dont le namespace n'est pas
défini, plutôt que de le laisser déployer dans `default`.

⚠️ **Le taux d'échec compte des pannes de la plateforme.** Les trois
`deploy-production` en échec le 2026-10-05 sont tombés sur un minikube arrêté ;
aucun n'a rien écrit en production, et le même job est passé ensuite sans
changement. DORA les compte comme des échecs de changement, et le collecteur ne
peut pas faire autrement : GitLab les classe en `script_failure`, comme un
manifeste faux. Sans eux, le taux serait de 50 % (6 sur 12). Le chiffre publié
reste 60 % : c'est une limite du poste de développement comme environnement,
pas une erreur de mesure.

⚠️ **Ces chiffres n'ont pas de valeur statistique.** Un taux d'échec sur 15
tentatives, un MTTR sur 4 observations : ce sont des faits, pas des tendances.
Les huit déploiements réussis tiennent sur trois journées (22 et 23 septembre,
5 octobre). Le délai de mise en production mesure surtout l'intervalle entre un
commit et le clic qui déclenche le déploiement — les deux jobs sont
`when: manual` : son maximum de 40,88 h est un `deploy-staging` fusionné un
samedi et déployé le lundi. Deux des temps de rétablissement (4,17 h et 0,25 h)
mesurent la relance d'un cluster, pas la réparation d'une application.

Les dix-sept jobs retenus, dans l'ordre (heure de fin, UTC ; les annotations
entre parenthèses ne sont pas produites par le collecteur) :

```
2026-09-22T14:36:39  deploy-production    failed   main
2026-09-22T18:01:37  deploy-staging       failed   develop
2026-09-22T18:37:05  deploy-staging       failed   develop
2026-09-22T18:47:39  deploy-staging       success  develop
2026-09-23T07:20:59  deploy-production    failed   main
2026-09-23T07:26:31  deploy-production    success  main
2026-09-23T09:28:52  deploy-production    success  main
2026-09-23T13:01:30  rollback-production  failed   main
2026-09-23T13:29:06  deploy-staging       success  develop
2026-09-23T13:34:44  rollback-production  success  main
2026-09-23T13:42:13  deploy-production    success  main
2026-10-05T06:52:31  deploy-staging       success  develop   (5296658a)
2026-10-05T07:58:13  deploy-production    failed   main      (cluster arrêté)
2026-10-05T12:08:40  deploy-production    success  main      (08a216b0)
2026-10-05T13:56:33  deploy-production    failed   v1.0.1    (cluster arrêté)
2026-10-05T14:00:58  deploy-production    failed   v1.0.1    (cluster arrêté)
2026-10-05T14:11:11  deploy-production    success  v1.0.1
```

Le rollback de production a été exercé le 2026-09-23, puis suivi d'un
redéploiement ; la production est passée ensuite sur `08a216b0`, puis sur
`1.0.1`, la même image sous son numéro de version.

### 9.2 ⚠️ Zéro mesuré et absence de donnée ne sont pas la même chose

C'est la règle qui gouverne tout le collecteur. Sur une fenêtre sans aucun
déploiement réussi :

- `deployment_frequency` vaut **`0.0`** : c'est une mesure. Zéro déploiement a
  bien eu lieu, sur une fenêtre connue.
- `lead_time_for_changes` vaut **`null`**, accompagné de sa raison : il n'existe
  aucune arrivée en production vers laquelle mesurer un délai.

Rendre le second en `0` afficherait un délai de mise en production de zéro
heure, c'est-à-dire **la performance parfaite** — là où il n'y a simplement
jamais eu de mise en production. Un test de `run_tests.sh` échoue si un
indicateur sans donnée ressort en `0`. Le tableau de bord respecte la même
règle : sur une période où l'index porte `valeur: null`, les tuiles affichent
`N/A`, pas `0` (`k8s/elk/dashboards/README.md`).

### 9.3 Comment un rollback est compté, et la limite qu'on assume

Un déploiement réussi puis annulé par un rollback compte comme un **échec**.
C'est la définition DORA du taux d'échec des changements : un changement qui a
dégradé la production. Ces cas sont comptés à part dans la sortie, pour qu'on
puisse les distinguer d'un job simplement rouge :

```json
"details": { "tentatives": 15, "echecs_directs": 7, "reussites_annulees": 2 }
```

Le collecteur retient les jobs en `success` **et** en `failed`
(`STATUTS_EXECUTES` dans `scripts/ci/collect_dora.py`) : un job qui a tourné
compte, quel que soit son verdict. `manual`, `skipped`, `created` et `canceled`
sont exclus — ils décrivent des déploiements qui n'ont pas eu lieu.

⚠️ **La limite est dans l'appariement, et elle est purement chronologique.** Un
rollback est rattaché au dernier déploiement réussi qui le précède, sans que son
issue ni son environnement n'entrent en ligne de compte. Les deux
`reussites_annulees` du 2026-09-23 en sont l'illustration :

- Le rollback de 13:01:30 a **échoué** sur un timeout du tunnel de l'agent. Il
  n'a donc rien annulé, et il compte quand même comme l'annulation du
  déploiement de 09:28:52.
- Le rollback de 13:34:44, joué en **production**, est rattaché au déploiement
  de 13:29:06 — qui visait **staging**. Il a bien annulé quelque chose, mais
  pas celui-là : il a ramené en arrière la production déployée à 09:28:52.

Une seule annulation a donc réellement eu lieu, là où le collecteur en compte
deux. Un appariement exact — rollback abouti, et même environnement — ramènerait
le taux d'échec de **60 % à 53,33 %** (8 échecs sur 15).

**Ce comptage est assumé, pas corrigé.** Un collecteur pessimiste surévalue le
taux d'échec ; l'erreur inverse produirait un chiffre flatteur que personne
n'aurait les moyens de contredire. Le corriger demanderait deux choses : lire
l'`environment:name` du job de rollback, et ne retenir que les rollbacks en
`success`.

### 9.4 Comment il est testé

Sur des **fixtures**, c'est-à-dire des réponses d'API enregistrées, et pas contre
le réseau : un test qui dépend d'un service tiers échoue les jours où ce service
est lent, et on finit par ne plus le croire.

Deux jeux, et la distinction est délibérée :

- `scripts/tests/fixtures/` — **réel**, enregistré verbatim depuis l'API : 44
  pipelines et les jobs des 7 pipelines ayant déclenché un déploiement. Il date
  d'avant le premier déploiement réussi : rejoué, il rend `0,0` déploiement par
  jour et 100 % d'échec, ce qui est correct pour la fenêtre qu'il décrit.
- `scripts/tests/fixtures/dora-scenario-fabrique/` — **fabriqué**, et nommé pour
  qu'on ne s'y trompe pas. Il contient des déploiements réussis, sans quoi les
  formules du délai et du MTTR ne seraient empruntées par aucun test.

Réenregistrer les fixtures réelles changerait la sortie de référence des tests
avec elles : c'est le prix d'une fixture verbatim, préférable à celui d'un test
qui appelle le réseau.

### 9.5 Rejouer

```shell
# Contre la vraie API, sans jeton (le projet miroir est public)
python3 scripts/ci/collect_dora.py --project 84606666 --days 30

# Hors ligne, sur les fixtures
python3 scripts/ci/collect_dora.py --fixtures scripts/tests/fixtures --days 0

# Injection dans Elasticsearch, pour le tableau de bord
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &
python3 scripts/ci/collect_dora.py --project 84606666 --days 30 \
  --elasticsearch http://127.0.0.1:9200 --es-index microcrm-dora
```

**Le job `dora-metrics`** (`.gitlab/ci/deploy.yml`) exécute ce collecteur sur
les pipelines de `develop`, de `main` et de tag, et publie le résultat en
artefact, `reports/dora.json`, conservé 30 jours.

⚠️ **Il n'alimente pas Elasticsearch** : l'instance vit dans le cluster, sans
adresse joignable depuis un conteneur de job. Le tableau de bord Kibana est donc
rempli à la main par la troisième commande ci-dessus, après un déploiement.

## 10. Les traces : OpenTelemetry et Elastic APM

Le back est tracé requête par requête : un agent OpenTelemetry dans la JVM, APM
Server dans la stack ELK, et l'application APM de Kibana pour lire le tout.
Aucune ligne du code Java n'est modifiée. Les pods de staging (`back:5296658a`)
et de production (`back:1.0.1`) émettent des traces depuis le 2026-10-05.

### 10.1 Ce que ça mesure, et ce que ça ne mesure pas

| Ce qu'on veut savoir                               | Sans les traces                | Avec les traces                                      |
| -------------------------------------------------- | ------------------------------ | ---------------------------------------------------- |
| Latence de l'API, par point d'entrée               | rien                           | **mesurée** : p50, p95, p99 par transaction          |
| Débit de l'API (requêtes par minute)               | rien                           | **mesuré**, calculé par APM Server depuis les traces |
| Taux d'échec, par point d'entrée                   | à déduire de `log.level`       | **mesuré** : `event.outcome` de chaque transaction   |
| Où passe le temps d'une requête (contrôleur, JDBC) | rien                           | **mesuré** : la cascade des spans                    |
| Les logs écrits par une requête donnée             | recherche à la main, par heure | **reliés** par `trace.id`, en staging                |
| Latence du front                                   | journal d'accès de Caddy (§5)  | inchangé — c'est la seule mesure du front            |
| CPU et mémoire des pods                            | rien                           | **rien** : pas de `metrics-server`                   |
| Métriques de la JVM (tas, GC, threads)             | rien                           | **rien** : `OTEL_METRICS_EXPORTER=none`, délibéré    |
| Ce que vit le navigateur de l'utilisateur          | rien                           | **rien** : le front n'est pas instrumenté            |

Autrement dit : les traces mesurent **ce que l'API fait de ses requêtes**, pas
**ce que ses pods consomment**. Les `resources` des Deployments restent des
estimations (§12).

### 10.2 La chaîne, maillon par maillon

```mermaid
flowchart TB
    accTitle: Le flux des traces, de la requête HTTP à Kibana APM
    accDescr: Dans le pod back, l'agent Java OpenTelemetry instrumente Spring Boot. Il envoie les traces en OTLP à APM Server, dans le namespace logging, qui les écrit dans Elasticsearch et en déduit débit, latence et taux d'échec. Le même agent écrit trace.id dans les logs JSON, que Filebeat collecte. Kibana APM lit les traces et retrouve leurs logs par trace.id.

    req(["Requête HTTP sur l'API"]) --> appli

    subgraph app["Namespaces microcrm-staging et microcrm-production"]
        subgraph pod["pod back : une seule JVM"]
            appli["Spring Boot<br/>bytecode instrumenté au chargement"]
            agent["Agent Java OpenTelemetry 2.31.1<br/>embarqué dans l'image, activé par<br/>JAVA_TOOL_OPTIONS de la ConfigMap"]
            mdc["Logs JSON ECS sur stdout<br/>avec trace.id et span.id"]
            appli -->|"spans"| agent
            agent -->|"écrit trace.id et span.id<br/>dans le MDC Logback"| mdc
        end
    end

    agent ==>|"OTLP http/protobuf, traces seules<br/>apm-server.logging.svc:8200<br/>attribut deployment.environment"| np

    subgraph logging["Namespace logging — créé par Terraform"]
        np{"NetworkPolicy : source dans<br/>un namespace applicatif ?"}
        refus["refusé — sur un CNI qui<br/>applique les policies"]
        apm["APM Server 8.19.7, sans Fleet<br/>port unique 8200, sans authentification"]
        fb["Filebeat, DaemonSet<br/>ne collecte que microcrm-staging"]
        es[("Elasticsearch<br/>templates APM installés par le plugin apm-data")]
        tr["traces-apm-default<br/>transactions et spans, rétention 10 jours"]
        me["metrics-apm.*<br/>débit, latence, taux d'échec<br/>calculés par APM Server"]
        lo["microcrm-logs-AAAA.MM.JJ<br/>logs portant trace.id"]
        kb["Kibana, application APM<br/>services, transactions, cascade de spans,<br/>onglet Logs par trace.id"]

        np -->|non| refus
        np -->|oui| apm
        apm --> tr
        apm -->|"agrège les traces"| me
        fb --> lo
        tr --> es
        me --> es
        lo --> es
        es --> kb
    end

    mdc -->|"/var/log/containers du nœud"| fb
    ope(["kubectl -n logging port-forward svc/kibana 5601"]) -.->|"aucun Ingress"| kb
```

_Source versionnée : `docs/schemas/traces-apm.mmd`, reprise dans
`ARCHITECTURE.md` §8.4._

1. **L'agent Java OpenTelemetry est dans l'image, mais inactif.**
   `back/Dockerfile` le télécharge dans une étape à part (version 2.31.1, depuis
   Maven Central) et vérifie son empreinte SHA-256 avant de le copier : un agent
   altéré s'exécuterait avec les droits de l'application et verrait passer
   chaque requête. La commande de l'image ne le charge pas.
2. **La ConfigMap l'active.** `JAVA_TOOL_OPTIONS=-javaagent:/app/opentelemetry-javaagent.jar`
   est lue par la JVM au démarrage. L'agent réécrit alors le bytecode des
   classes instrumentées à leur chargement : c'est ce qui dispense de toucher
   au code.
3. **Les traces partent en OTLP**, en `http/protobuf`, vers
   `http://apm-server.logging.svc:8200`. Seules les traces partent : métriques
   et logs sont coupés à la source (`OTEL_METRICS_EXPORTER` et
   `OTEL_LOGS_EXPORTER` à `none`).
4. **APM Server** (8.19.7, un pod, sans Fleet ni Elastic Agent) reçoit l'OTLP sur
   son port unique, le traduit en documents Elasticsearch, et **calcule
   lui-même** les agrégats de débit, de latence et de taux d'échec.
5. **Elasticsearch** range le tout dans les data streams standard d'APM —
   `traces-apm-default` pour les transactions et les spans, `metrics-apm.*` pour
   les agrégats. Leurs templates ne viennent ni d'APM Server ni de Kibana : c'est
   le plugin `apm-data` d'Elasticsearch qui les installe, avec une rétention de
   10 jours pour les traces et de 90 jours pour les agrégats à la minute.
6. **Kibana** lit ces data streams dans son application APM, sans aucun réglage.
7. **La corrélation avec les logs** ne passe pas par APM Server. L'agent écrit
   l'identifiant de la trace dans le MDC Logback, l'encodeur ECS le recopie dans
   chaque ligne JSON, et Filebeat collecte cette ligne comme n'importe quelle
   autre (§2). Kibana retrouve ensuite les logs d'une trace par `trace.id`.

Les huit clés qui règlent l'agent, toutes dans la ConfigMap `microcrm-config` :

| Clé                           | Valeur                                           | Rôle                                       |
| ----------------------------- | ------------------------------------------------ | ------------------------------------------ |
| `JAVA_TOOL_OPTIONS`           | `-javaagent:/app/opentelemetry-javaagent.jar`    | L'interrupteur                             |
| `OTEL_SERVICE_NAME`           | `microcrm`                                       | Nom du service dans Kibana APM             |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://apm-server.logging.svc:8200`             | Destination                                |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf`                                  | Protocole                                  |
| `OTEL_TRACES_EXPORTER`        | `otlp`                                           | Les traces partent                         |
| `OTEL_METRICS_EXPORTER`       | `none`                                           | Les métriques de l'agent ne partent pas    |
| `OTEL_LOGS_EXPORTER`          | `none`                                           | Les logs passent déjà par Filebeat         |
| `OTEL_RESOURCE_ATTRIBUTES`    | `deployment.environment=staging` ou `production` | Sépare les deux environnements dans Kibana |

Deux autres variables, `OTEL_INSTRUMENTATION_COMMON_LOGGING_TRACE_ID_KEY`
et `…_SPAN_ID_KEY`, sont posées par l'**image** (`back/Dockerfile`), pas par la
ConfigMap : elles décrivent le format des logs de cette image et doivent
voyager avec elle.

Comme `SPRING_PROFILES_ACTIVE` (§3), ces clés existent en **deux exemplaires** —
`k8s/base/configmap.yaml` et `helm/microcrm/templates/configmap.yaml` — et
`validate_k8s.sh` compare les deux rendus clé par clé.

### 10.3 Les choix, et leurs raisons

**L'agent est embarqué mais éteint par défaut.** Les jobs k6 de la CI démarrent
l'image du back comme service, sans aucun collecteur OTLP. Activé d'office,
l'agent y journaliserait en boucle ses échecs d'export et ralentirait le
démarrage que la mesure de performance chronomètre. `JAVA_TOOL_OPTIONS` plutôt
qu'un `-javaagent` dans la commande du conteneur : la commande reste celle de
l'image, et désactiver les traces se résume à retirer une clé.

**`http/protobuf` plutôt que gRPC**, alors qu'APM Server accepte les deux sur le
même port : c'est du HTTP/1.1 ordinaire, qu'un `curl` suffit à tester, là où
gRPC impose HTTP/2 et un outil dédié pour le moindre diagnostic.

**Les métriques de l'agent restent coupées.** Ce dont l'application APM a
besoin — débit, latence, taux d'échec par transaction — APM Server le calcule à
partir des traces. Exporter aussi les métriques ajouterait celles de la JVM et
des histogrammes HTTP, toutes les 60 secondes, dans un data stream de plus sur
un PVC de 5 Gio, pour des séries qu'aucun écran n'exploite. Réversible sans
reconstruire l'image : passer la clé à `otlp`.

**Les logs ne sont pas exportés en OTLP.** Ils arrivent déjà par Filebeat. Les
exporter aussi les indexerait deux fois, dans deux data streams différents, et
chaque ligne apparaîtrait en double sous sa trace.

**Le nom du service est aligné sur celui des logs.** `OTEL_SERVICE_NAME` vaut
`microcrm`, comme le `service.name` des logs ECS (`spring.application.name`).
L'onglet « Logs » d'un service dans Kibana APM filtre sur ce champ : avec deux
noms différents, il resterait vide. Les traces sont alignées sur les logs plutôt
que l'inverse, pour ne pas changer le JSON déjà indexé.

**L'environnement est une étiquette, et sa valeur de base est volontairement
fausse.** Staging et production écrivent dans le même APM Server ; c'est
`deployment.environment` qui les sépare. La base porte `non-surcharge` : chaque
overlay doit la remplacer, et `validate_k8s.sh` échoue si elle survit au rendu.
Une trace étiquetée `non-surcharge` désignerait un patch oublié au lieu de se
faire passer pour un vrai environnement.

**APM Server tourne sans Fleet.** C'est possible en 8.19 parce qu'Elasticsearch
installe lui-même les templates APM (plugin `apm-data`, actif par défaut depuis
la 8.15). Un binaire et un fichier de configuration : ni Fleet, ni Elastic
Agent, ni intégration à installer.

**APM Server vit dans la stack ELK, pas à part**, pour une raison
fonctionnelle : Kibana ne relie une trace à ses logs que si les deux sont dans
le même Elasticsearch.

**Aucune authentification, et le périmètre est tenu par le réseau.** Un jeton
sur APM Server ne protégerait qu'une porte d'une maison sans serrure —
Elasticsearch lui-même n'en a pas (§12). Le Service est en `ClusterIP`, sans
Ingress, et une `NetworkPolicy` décrite dans Terraform
(`terraform/environments/logging/main.tf`) n'ouvre le port 8200 qu'aux
namespaces `microcrm-staging` et `microcrm-production`. C'est la **seule**
policy du namespace `logging`, et elle ne sélectionne que les pods d'APM
Server.

**Le dimensionnement est mesuré, pas arrondi.** 50m / 64Mi en requests, 500m /
256Mi en limits. La mémoire d'APM Server relevée sur ce cluster : environ
21 Mio au repos, 54 Mio au pic d'une rafale de 1 000 requêtes OTLP en 4,3
secondes.

**La file de l'agent est bornée, et elle jette en silence.** L'agent garde
2 048 spans en attente par défaut ; pleine, elle perd les suivants sans erreur
côté application. C'est la raison du `RollingUpdate` d'APM Server : pas de
coupure de la réception pendant un redémarrage.

### 10.4 Mesures

**Dans le cluster, le 2026-10-05**, après le déploiement de `5296658a` en
staging et de `1.0.1` en production, sur des requêtes envoyées aux deux API :

| Ce qui a été regardé                       | Ce qui a été trouvé                                                                                            |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| Images du back                             | staging `back:5296658a`, production `back:1.0.1` (même digest que `back:08a216b0`), agent compris              |
| ConfigMap `microcrm-config`                | 11 clés dans chaque namespace, dont `JAVA_TOOL_OPTIONS` et `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=…` |
| `traces-apm*`, staging                     | **534** documents `service.environment=staging` en 15 minutes                                                  |
| `traces-apm*`, après la mise en production | **187** documents `production` et **180** `staging` en 10 minutes                                              |
| Logs portant un `trace.id`                 | présents dans les logs du back                                                                                 |
| Pod `back` de production                   | `Running`, 0 redémarrage ; `/actuator/health` à `UP`                                                           |
| `NetworkPolicy` d'APM Server               | **absente** du cluster : `terraform-apply-logging` n'a pas été rejoué depuis son ajout                         |

Le trafic est provoqué, pas celui d'utilisateurs : la mesure prouve que la
chaîne fonctionne de bout en bout dans le cluster, elle ne fournit pas une
latence de référence en service.

**Sur un conteneur local, le 2026-10-02.** La seule mesure de latence de l'API
disponible vient d'un essai sur le poste : l'image du back avec l'agent, lancée
dans un conteneur Docker avec les huit clés de la ConfigMap, APM Server atteint
par `kubectl port-forward`, environnement étiqueté `verification-poste`. 303
requêtes HTTP en 18 secondes :

| Ce qui a été relevé                        | Valeur                                                                                    |
| ------------------------------------------ | ----------------------------------------------------------------------------------------- |
| Services vus par Kibana APM                | **1** : `microcrm`, agent `opentelemetry/java` 2.31.1, environnement `verification-poste` |
| Documents dans `traces-apm-default`        | **1 536** : 325 transactions et 1 211 spans                                               |
| Dont transactions HTTP                     | 303 ; les 22 autres sont les requêtes JDBC et les appels de repository du démarrage       |
| Spans                                      | 904 internes à l'application, 307 de base de données (`hsqldb`)                           |
| Agrégats calculés par APM Server           | présents dans quatre data streams `metrics-apm.*.1m`, moins de deux minutes après         |
| Échecs d'export dans le journal de l'agent | 0                                                                                         |

La latence, par transaction :

| Transaction              | Requêtes | p50     | p95     | p99      | Statuts            |
| ------------------------ | -------- | ------- | ------- | -------- | ------------------ |
| `GET /{repository}`      | 200      | 4,20 ms | 5,65 ms | 8,60 ms  | 200                |
| `GET /{repository}/{id}` | 80       | 2,64 ms | 3,41 ms | 6,03 ms  | 200 × 40, 404 × 40 |
| `POST /{repository}`     | 20       | 3,01 ms | 5,02 ms | 24,25 ms | 201                |

`{repository}` est la route générique de Spring Data REST : `/persons` et
`/organizations` y sont confondus. Séparés par `url.path`, ils donnent
4,20 / 5,65 / 7,16 ms pour `GET /persons` et 4,17 / 5,55 / 8,60 ms pour
`GET /organizations` (100 requêtes chacun).

**La corrélation, constatée des deux côtés.** Les lignes JSON écrites par le
conteneur pendant une requête portent `"trace.id"` et `"span.id"`, et le
`trace.id` de l'une d'elles se retrouve dans `traces-apm-default`, sur la
transaction qui l'a produite.

**Le surcoût de l'agent, mesuré une fois.** Même image, même série de requêtes,
avec et sans `JAVA_TOOL_OPTIONS` : démarrage de Spring Boot en 3,39 s contre
2,45 s, et 408 Mio contre 292 Mio de mémoire après la série (`docker stats`).
Une seule mesure, sur un conteneur sans limite mémoire : c'est un ordre de
grandeur, pas un dimensionnement. Le commentaire de
`k8s/base/back-deployment.yaml` cite cette mesure ; les valeurs de `resources`
ne sont pas recalées sur elle, et l'écart reste à confronter à la limite de
768 Mio du pod.

![Kibana APM, liste des services le 2 octobre 2026 : un seul service, microcrm, environnement verification-poste, latence moyenne 4,6 ms, débit 0,2 transaction par minute sur 24 heures, taux d'échec 0 %.](docs/captures/kibana-apm-services-2026-10-02.png)

![Kibana APM, transactions du service microcrm le 2 octobre 2026 : courbes de latence, de débit et de taux d'échec, puis la table des transactions par route, GET /{repository} en tête.](docs/captures/kibana-apm-transactions-microcrm-2026-10-02.png)

⚠️ **Réserves sur ces chiffres.** Ce sont les latences d'un conteneur local, sur
un poste chargé, avec une base de démonstration presque vide : elles prouvent
que la mesure existe, pas ce que vaut l'API de staging. La seconde capture
agrège aussi les requêtes d'un autre essai local (environnement
`demo-alerting`) : ses chiffres diffèrent donc du tableau. Les traces d'essai se
reconnaissent à leur environnement et expirent après dix jours.

### 10.5 Les pièges

Ils sont dans les commentaires du code. Ils sont repris ici parce qu'aucun ne
produit de message d'erreur utile.

**Le port est 8200, pas 4318, et l'URL s'arrête au port.** APM Server
multiplexe tout sur un seul port ; les ports OTLP « standard » d'un
OpenTelemetry Collector (4317, 4318) n'existent pas ici. Et en `http/protobuf`,
l'agent ajoute lui-même `/v1/traces` à l'URL de base : l'écrire donnerait
`/v1/traces/v1/traces`, un 404. Dans les deux cas l'agent n'en dit qu'une ligne
par minute.

**Protobuf, pas JSON.** L'OTLP/HTTP d'APM Server 8.19 refuse le JSON :
`failed to unmarshal request body`, code 400.

**⚠️ Un rollback ramène l'image, pas la ConfigMap.** Si le fichier de l'agent
est absent, la JVM refuse de démarrer (`Error opening zip file or JAR manifest
missing`) et le pod boucle en `CrashLoopBackOff`. Or `kubectl rollout undo` —
donc `rollback.sh`, et l'annulation automatique de `deploy.sh` — ramène l'image
précédente mais laisse la ConfigMap. Revenir à une image qui n'embarque pas
l'agent avec `JAVA_TOOL_OPTIONS` en place, c'est un pod neuf qui ne démarre
jamais. L'ancien reste en service grâce à `maxUnavailable: 0`, mais le rollback
n'aboutit pas. Dans ce cas précis : retirer d'abord la clé.

**Les noms de champs décident de tout.** Par défaut l'agent écrit `trace_id` et
`span_id` dans le MDC, que Kibana ne relie à rien : ECS attend `trace.id` et
`span.id`. Trois façons de casser ce renommage sans la moindre erreur :

- surcharger la variable par une valeur **vide** — l'agent prend la chaîne vide
  pour nom de clé, et le JSON contient `"":"<identifiant>"` ;
- la redéfinir dans la ConfigMap — `envFrom` l'emporte sur l'`ENV` de l'image ;
- remplacer l'encodeur ECS par un format texte, ou par un encodeur qui filtre
  le MDC.

**Sans `observability:logSources`, l'onglet « Logs » d'une trace reste vide**,
alors que les logs portent bien le `trace.id`. Kibana ne cherche les logs que
dans `logs-*-*`, `logs-*` et `filebeat-*` ; Filebeat écrit ici dans
`microcrm-logs-*`, qu'aucun des trois ne couvre. Le motif est ajouté par
`uiSettings.overrides`, dans un `kibana.yml` monté en ConfigMap
(`k8s/elk/kibana-config.yaml`) — un fichier, parce que le point d'entrée de
l'image Kibana ne traduit en réglage qu'une liste fermée de variables
d'environnement, et que `uiSettings.*` n'y figure pas.

**Ne pas renommer les index d'APM** par symétrie avec `microcrm-logs-*`.
L'application APM ne sait lire que les noms standard, et un index renommé
perdrait son template : une trace indexée en mapping dynamique ne s'affiche
plus dans la cascade.

**Une ligne de texte au milieu du JSON.** La JVM écrit
`Picked up JAVA_TOOL_OPTIONS: …` sur la sortie d'erreur au démarrage. Filebeat
l'indexe telle quelle.

**Deux faux positifs Trivy, écrits comme tels** (`.trivyignore.yaml`).
`DS-0031` signale tout `ENV` dont le nom contient `KEY` : les deux variables de
renommage ci-dessus en font partie, et « key » y désigne une clé de MDC.
`KSV-0109` cherche le mot « secret » dans les valeurs d'une ConfigMap : il le
trouve dans un commentaire d'`apm-server.yml`. Les deux exceptions sont limitées
à leur fichier et expirent le 2026-12-31. Et un point qui n'est pas un faux
positif : Trivy voit le jar de l'agent comme **un seul paquet**, ses
dépendances embarquées lui sont invisibles. Un « 0 vulnérabilité » sur ce jar
n'est pas un certificat ; c'est le SBOM publié avec l'agent qu'il faut scanner à
chaque montée de version.

### 10.6 Rejouer, et vérifier

```shell
# 1. APM Server tourne, et répond
kubectl -n logging rollout status deployment/apm-server --timeout=120s
kubectl -n logging port-forward svc/apm-server 8200:8200 &
curl -s http://127.0.0.1:8200/          # sa version, en JSON

# 2. L'agent est bien chargé dans le back
kubectl -n microcrm-staging logs deploy/back | grep -m1 'Picked up JAVA_TOOL_OPTIONS'

# 3. Produire quelques requêtes tracées
kubectl -n microcrm-staging port-forward svc/back 18081:8080 &
for i in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:18081/persons; done

# 4. Les traces sont arrivées
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &
curl -s 'http://127.0.0.1:9200/_cat/indices/*apm*?v&s=index'
curl -s 'http://127.0.0.1:9200/traces-apm*/_count?q=processor.event:transaction'

# 5. La latence par point d'entrée, sans passer par Kibana
curl -s -X POST 'http://127.0.0.1:9200/traces-apm*/_search?size=0' \
  -H 'Content-Type: application/json' -d '{
    "query": {"term": {"processor.event": "transaction"}},
    "aggs": {"par_nom": {"terms": {"field": "transaction.name", "size": 20},
      "aggs": {"latence": {"percentiles": {
        "field": "transaction.duration.us", "percents": [50, 95, 99]}}}}}}'

# 6. La corrélation : des logs portent un trace.id
curl -s 'http://127.0.0.1:9200/microcrm-logs*/_count?q=_exists_:trace.id'

# 7. Kibana > Observability > APM > Services > microcrm
kubectl -n logging port-forward svc/kibana 5601:5601
```

Les durées sont en **microsecondes** dans `transaction.duration.us`. Hors
cluster, `bash scripts/tests/validate_k8s.sh` vérifie la cohérence de toute la
chaîne : l'endpoint de la ConfigMap désigne bien le Service d'APM Server, le
port de la `NetworkPolicy` est bien celui du conteneur, les quatre images
Elastic partagent leur version, et chaque overlay pose son environnement.

### 10.7 Les limites

- **Le back seul est tracé.** Le front Angular n'est pas instrumenté (`rum`
  désactivé dans APM Server) : il faudrait exposer APM Server hors du cluster,
  donc sans authentification derrière un Ingress. Une trace commence à l'API,
  pas au clic.
- **Les logs de production ne sont pas collectés.** Filebeat ne lit que
  `microcrm-staging`. Les traces de production arrivent dans Kibana ; leur
  onglet « Logs » reste vide.
- **Aucune authentification sur APM Server**, et la `NetworkPolicy` qui borne
  son accès n'est pas appliquée dans le cluster (§10.4) ; une fois créée, le
  CNI par défaut de minikube ne l'appliquerait de toute façon pas. Sur ce
  cluster, n'importe quel pod peut y écrire des traces.
- **Aucun échantillonnage n'est réglé** : l'agent trace toutes les requêtes,
  sondes du kubelet comprises. Sans conséquence à ce débit ; à régler avant
  toute charge réelle.
- **Pas de latence en service** : seul du trafic provoqué a traversé la chaîne
  dans le cluster. Les chiffres de latence disponibles sont ceux du conteneur
  local (§10.4).
- **Les noms de transaction sont ceux des routes de Spring Data REST**, pas
  ceux des ressources : `/persons` et `/organizations` sont confondus sous
  `GET /{repository}`. Les séparer demande de filtrer sur `url.path`.
- **Le surcoût de l'agent n'est mesuré qu'une fois, hors cluster** (§10.4) :
  environ une seconde de démarrage et une centaine de Mio. Sous la limite de
  768 Mio et d'1 CPU du pod, rien n'est mesuré : le budget du `startupProbe`
  (150 s) est conservé par raisonnement, et `k8s/base/back-deployment.yaml`
  dit lui-même que la mesure reste à faire.
- **Une seule JVM, donc pas de trace « distribuée ».** Les traces décrivent ce
  qui se passe dans le back. Il n'y a ni second service ni base externe à
  traverser : l'intérêt de la propagation entre services n'est pas démontré
  ici.
- **Rien ne teste la chaîne de bout en bout en CI.** `validate_k8s.sh` vérifie
  que les manifestes sont cohérents entre eux, pas qu'une trace arrive.

## 11. L'alerting

Huit règles d'alerte couvrent trois familles — disponibilité, performance,
sécurité. Elles sont versionnées dans `k8s/elk/alerting/`, installées par
`scripts/monitoring/install_alerting.py`, et chacune a été déclenchée puis
rétablie sur le cluster. Le détail règle par règle est dans
`k8s/elk/alerting/README.md` ; cette section en donne le raisonnement, les
seuils, les preuves et les limites.

### 11.1 Le mécanisme, et pourquoi celui-là

**Des règles Kibana natives, de type `.es-query`, écrites en ES|QL.** Sur cette
stack (8.19.7, licence `basic`, sécurité désactivée), elles s'exécutent sans clé
d'API ni utilisateur. ElastAlert n'est donc pas nécessaire — un composant de
moins à faire tourner et à mettre à jour.

**Le livrable est un dossier de fichiers, pas une liste dans Kibana.** Une règle
créée à la souris vit dans l'index `.kibana` d'un pod et disparaît avec lui — et
une alerte disparue ne prévient pas qu'elle a disparu. C'est le raisonnement du
§8, appliqué aux règles : un fichier JSON par règle dans
`k8s/elk/alerting/rules/`, dont le nom est l'identifiant de la règle dans
Kibana. C'est cet identifiant choisi qui rend l'installation idempotente :
première exécution « 8 règles créées », seconde « 8 règles mises à jour »,
toujours huit au total.

Trois réglages sont nécessaires, et chacun est un piège si on l'ignore.

**1. La clé de chiffrement de Kibana.** Sans
`xpack.encryptedSavedObjects.encryptionKey`, Kibana tire une clé au hasard à
chaque démarrage : `GET /api/alerting/_health` renvoie
`"has_permanent_encryption_key": false`, et `GET /api/actions/connectors`
répond **500**. Cette clé est un secret et le dépôt est public : elle n'est
écrite dans aucun fichier. Elle vit dans le Secret `kibana-encryption-key` du
namespace `logging`, créé hors dépôt avec une valeur aléatoire
(`install_alerting.py --secret`), et `k8s/elk/kibana-deployment.yaml` la lit par
`secretKeyRef` — `optional: true`, pour qu'un `kubectl apply -k` sur un cluster
neuf donne tout de même un Kibana qui démarre.

**2. Les connecteurs que la licence autorise.** Relu sur l'instance par
`GET /api/actions/connector_types` :

| Type de connecteur | Licence minimale | Utilisable ici |
| ------------------ | ---------------- | -------------- |
| `.index`           | basic            | oui            |
| `.server-log`      | basic            | oui            |
| `.webhook`         | gold             | **non**        |
| `.slack`           | gold             | **non**        |
| `.email`           | gold             | **non**        |

Chaque règle déclenche donc deux actions : un document dans l'index
`microcrm-alerts`, et une ligne dans le journal du pod Kibana. Les deux
connecteurs sont **préconfigurés** dans `k8s/elk/kibana-config.yaml`
(`xpack.actions.preconfigured`) : identifiant fixe, présents dès le démarrage,
non modifiables depuis l'interface.

**3. ES|QL plutôt que le seuil sur index.** Le type `.index-threshold` ne
calcule que `count`, `avg`, `min`, `max` et `sum` : pas de percentile, donc pas
de p95. En ES|QL, la règle se déclenche dès que la requête renvoie une ligne ;
le seuil est écrit **dans la requête**, ce qui permet de la rejouer telle quelle
dans _Dev Tools_ pour comprendre une alerte.

### 11.2 Les huit règles, leur seuil et sa justification

Toutes s'évaluent **chaque minute**. Les statistiques qui justifient les seuils
ont été relevées dans Elasticsearch le 2026-10-02.

| Règle                          | Famille       | Source                        | Fenêtre | Seuil                                     | Ce qui justifie le seuil                                                                                                                    |
| ------------------------------ | ------------- | ----------------------------- | ------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `dispo-front-muet`             | disponibilité | logs Caddy, staging           | 3 min   | moins de 1 requête                        | Les sondes du kubelet produisent 90 lignes par 5 minutes (médiane sur 7 jours), soit 54 attendues en 3 minutes : zéro n'est jamais un creux |
| `dispo-back-redemarrages`      | disponibilité | logs du back, staging         | 15 min  | 2 démarrages ou plus                      | 12 démarrages en 47 jours, jamais plus d'un par quart d'heure sauf une fois ; un déploiement normal en produit un seul                      |
| `dispo-back-echecs-requetes`   | disponibilité | logs du back, staging         | 5 min   | 1 exception ou plus                       | Aucune ligne `ERROR` ni `error.type` en 47 jours (325 `INFO`, 49 `WARN`, 0 `ERROR`) ; chaque occurrence est une requête terminée en 500     |
| `dispo-api-5xx`                | disponibilité | traces APM, par environnement | 5 min   | 1 réponse 5xx ou plus                     | 0 réponse 5xx sur les 401 transactions relevées avant l'essai                                                                               |
| `perf-front-p95`               | performance   | `caddy.duration`, staging     | 5 min   | p95 > 100 ms, sur 20 requêtes ou plus     | Sur 624 tranches de 5 minutes, p95 médian de 1,54 ms ; 12 tranches dépassent 100 ms, 4 avec 20 requêtes ou plus, toutes machine saturée     |
| `perf-api-p95`                 | performance   | traces APM, par environnement | 5 min   | p95 > 250 ms, sur 20 transactions ou plus | Sur 401 transactions : p95 de 5,6 et 17,4 ms selon l'environnement, maximum 97 ms. **Échantillon petit et hors cluster : seuil à recaler**  |
| `secu-front-chemins-sensibles` | sécurité      | `caddy.request.uri`, staging  | 5 min   | 1 requête ou plus                         | Sur 68 493 requêtes en 30 jours, le seul chemin demandé est `/` ; une requête vers `/.env` ou `/.git` suffit à dire que quelqu'un cherche   |
| `secu-api-rafale-4xx`          | sécurité      | traces APM, par environnement | 5 min   | 20 réponses 4xx ou plus                   | Le trafic nominal relevé n'en produit aucune (0 sur 98) ; une énumération d'identifiants en produit des dizaines (40 et 64 observées)       |

La requête exacte de chaque règle est le champ `params.esqlQuery.esql` de son
fichier. Les motifs surveillés par `secu-front-chemins-sensibles` sont `.env`,
`.git`, `.aws`, `..`, `%2e%2e`, `etc/passwd`, `id_rsa`, `wp-`, `phpmyadmin`,
`.php`, `cgi-bin` et `actuator`.

**Ce que les données permettent, et ce qu'elles interdisent.** Les règles sont
écrites à partir de ce qui est réellement collecté, pas de ce qu'on aimerait
surveiller :

- **Filebeat ne collecte que `microcrm-staging`** (§4). Aucune des cinq règles
  fondées sur les logs ne voit la production.
- **Le journal d'accès du front ne contient que les sondes de Kubernetes** en
  temps normal : 41 430 requêtes en 7 jours, toutes `GET /` en 200. C'est un
  battement de cœur régulier, donc un bon signal de disponibilité — et un
  mauvais signal de trafic.
- **Le front ne renvoie jamais de 4xx** (§5) : un « pic de 404 » ne peut pas
  exister de ce côté. C'est le chemin demandé qui est surveillé.
- **Le back ne journalise pas ses accès.** Il n'écrit rien pour un 400 ou un
  404, et une ligne `WARN` portant `error.type` pour un 500.
- **L'application n'a pas d'authentification** : ni 401 ni 403 ne peuvent se
  produire. La règle de sécurité côté API compte donc les 4xx en général.
- **Les trois règles fondées sur les traces** regroupent par
  `service.environment` : elles portent sur staging **et** production, dont les
  back émettent des traces.

### 11.3 Les preuves de déclenchement — 2026-10-02

Les huit règles ont été déclenchées, puis se sont rétablies. Heures UTC,
relevées dans l'index `microcrm-alerts` :

| Règle                          | Provoquée par                                                       | Déclenchée | Valeur   | Rétablie |
| ------------------------------ | ------------------------------------------------------------------- | ---------- | -------- | -------- |
| `dispo-back-echecs-requetes`   | `GET /persons/abc` sur le back de staging, qui répond 500           | 19:37:35   | 1        | 19:40:35 |
| `dispo-api-5xx`                | la même requête, sur un back instrumenté lancé sur le poste         | 19:37:35   | 1        | 19:40:35 |
| `dispo-back-redemarrages`      | deux `kubectl rollout restart deploy/back` en staging               | 19:38:38   | 3        | 19:53:39 |
| `secu-api-rafale-4xx`          | 60 `GET /persons/<identifiant inexistant>` sur le back instrumenté  | 19:38:47   | 64       | 19:43:44 |
| `secu-front-chemins-sensibles` | 8 requêtes (`/.env`, `/.git/config`, `/wp-login.php`…) sur le front | 19:38:50   | 8        | 19:43:50 |
| `perf-api-p95`                 | back instrumenté bridé à 0,05 CPU                                   | 19:40:41   | 269,2 ms | 19:44:41 |
| `perf-front-p95`               | front de staging bridé à 10 m CPU, sous charge                      | 19:45:44   | 909,1 ms | 19:51:45 |
| `dispo-front-muet`             | `kubectl scale deploy/front --replicas=0` en staging                | 19:50:39   | 0        | 19:51:39 |

L'index porte **16 documents** : un par changement d'état, huit `declenchee` et
huit `retablie`. Les mêmes lignes sont dans le journal du pod Kibana, par
exemple :

```
[2026-10-02T19:50:39.027+00:00][WARN ][plugins.actions.server-log] Server log: ALERTE [disponibilite/critique] MicroCRM - disponibilité - front de staging muet - valeur 0 requêtes (seuil : moins de 1 requête servie en 3 min) - …
```

État final, lu par `install_alerting.py --etat` : huit règles activées, dernière
exécution réussie, aucune alerte active.

![Kibana, liste des règles d'alerte le 2 octobre 2026 : huit règles MicroCRM, toutes activées, dernière exécution réussie pour les huit.](docs/captures/kibana-alertes-liste-des-regles-2026-10-02.png)

![Tableau de bord Kibana de suivi des alertes, sur une heure, le 2 octobre 2026 : huit déclenchements, dont quatre de disponibilité, deux de performance et deux de sécurité, et le journal des seize changements d'état.](docs/captures/kibana-alertes-suivi-declenchements-2026-10-02.png)

⚠️ **Quatre réserves, pour ne pas sur-lire ce tableau.**

- **Les trois règles fondées sur les traces sont prouvées hors cluster**, sur un
  conteneur lancé sur le poste (environnement `demo-alerting`). Elles n'ont pas
  été re-déclenchées sur les pods déployés.
- **`dispo-back-redemarrages` affiche 3 et non 2** : `minikube start` avait
  lui-même démarré le back douze minutes plus tôt.
- **Le front ne peut pas être ralenti par un client lent** — le `port-forward`
  absorbe la lenteur. Il faut lui retirer du CPU ; sa limite a été remise à
  200 m ensuite.
- **Ces déclenchements sont provoqués, pas subis.** Ils prouvent que chaque
  règle sonne et se rétablit ; ils ne disent rien de sa tenue sur plusieurs
  jours, faux positifs compris.

**Un défaut applicatif rendu visible.** `GET /persons/abc` renvoie **500**
(`ConversionFailedException`) au lieu de 400. Ce n'est pas un défaut de
l'alerting : c'est un défaut de l'application, que la règle
`dispo-back-echecs-requetes` signale. Il n'est pas corrigé.

### 11.4 Rejouer

L'installation complète est au §13. Pour provoquer un déclenchement, une fois
les règles installées et les `port-forward` ouverts :

```shell
# Sécurité — immédiat et sans effet de bord
kubectl -n microcrm-staging port-forward svc/front 8080:80 &
for chemin in /.env /.git/config /wp-login.php; do
  curl -s -o /dev/null "http://127.0.0.1:8080$chemin"
done

# Disponibilité — une exception du back
kubectl -n microcrm-staging port-forward svc/back 8081:8080 &
curl -s -o /dev/null http://127.0.0.1:8081/persons/abc

# Disponibilité — front muet (staging uniquement ; compter 4 minutes)
kubectl -n microcrm-staging scale deploy/front --replicas=0
kubectl -n microcrm-staging scale deploy/front --replicas=1

# Lire le résultat, une à deux minutes plus tard
curl -s 'http://127.0.0.1:9200/microcrm-alerts/_search?sort=@timestamp:desc&size=5'
kubectl -n logging logs deploy/kibana | grep server-log
scripts/monitoring/install_alerting.py --etat
```

Pour modifier une règle : éditer son fichier, relancer
`install_alerting.py`. Une retouche faite dans l'interface de Kibana est écrasée
à l'installation suivante — c'est voulu.

### 11.5 Les limites

- **Aucune notification ne sort de Kibana.** Une alerte s'écrit dans un index et
  dans un journal : il faut ouvrir le tableau de bord pour la voir. Les
  connecteurs webhook, Slack et e-mail exigent la licence `gold`. Le pont vers
  `scripts/ci/notify.py` — un programme qui relirait `microcrm-alerts` et
  pousserait les nouvelles lignes vers `NOTIFY_WEBHOOK_URL` — n'est pas fait.
- **L'alerting ne se surveille pas lui-même.** Si Kibana ou Elasticsearch tombe,
  les règles ne s'évaluent plus et aucune alerte ne le dit. Un tableau de bord
  vide se lit alors comme « tout va bien ».
- **La production n'est couverte qu'à moitié.** Les cinq règles sur logs ne
  voient que staging. Les trois règles sur traces portent sur staging et
  production, mais n'ont sonné que sur un conteneur local (§11.3).
- **L'indisponibilité du cluster lui-même n'est détectée par rien.** Kibana vit
  dans ce cluster : quand minikube s'arrête (après un redémarrage de Docker
  Desktop, par exemple), l'alerting s'arrête avec lui, et l'arrêt ne se
  découvre qu'à l'échec suivant d'un déploiement. Une sonde externe au cluster
  est la seule réponse.
- **Un back arrêté sans redémarrer n'est détecté par aucune règle sur logs.** À
  zéro replica, il n'écrit rien : le back n'a pas de battement de cœur dans ses
  logs.
- **Aucune métrique d'infrastructure** : ni CPU, ni mémoire, ni disque, ni état
  des pods. Un `CrashLoopBackOff` n'est vu que par ses effets, et le remplissage
  du PVC d'Elasticsearch n'est pas surveillé.
- **`dispo-front-muet` sonne au réveil d'un poste mis en veille** : l'alerte est
  exacte — rien n'a été servi — et sans intérêt.
- **Deux seuils reposent sur peu de données** : `perf-api-p95` et
  `secu-api-rafale-4xx` sont calés sur quelques centaines de transactions
  d'essai, hors cluster.
- **Aucune rétention sur `microcrm-alerts`**, comme sur le reste de la stack.
- **L'installation n'est pas automatisée** : aucun job de CI ne lance
  `install_alerting.py`. Les tests de `run_tests.sh` contrôlent les fichiers de
  règles et le script contre de faux binaires, pas une instance.
- **La clé de chiffrement ne survit pas à `minikube delete`.** Sur un cluster
  reconstruit, une nouvelle clé est tirée et les règles sont réinstallées depuis
  les fichiers ; rien n'est perdu, précisément parce qu'elles ne vivent pas dans
  l'instance.

**Ce qui n'est pas vérifié.** La création réelle du Secret par
`install_alerting.py --secret` : seuls la branche « existe déjà », la syntaxe en
`--dry-run=client` et le chemin complet contre le faux `kubectl` des tests sont
éprouvés. Le démarrage de Kibana **sans** le Secret, sur un cluster neuf, n'a
pas été rejoué. Et aucune règle fondée sur les traces n'a été déclenchée sur un
pod du cluster.

## 12. Ce qui n'est pas fait

**La sécurité d'Elasticsearch est désactivée** (`xpack.security.enabled: false`).
En 8.x elle est active par défaut, et Kibana ne peut s'y connecter sans
identifiants ni certificat. Le choix est assumé pour une stack locale de
démonstration ; il serait inacceptable ailleurs, et c'est la première chose à
reprendre si cette stack devait sortir du poste.

**Aucun Ingress.** L'accès à Kibana se fait par
`kubectl -n logging port-forward svc/kibana 5601:5601`. Exposer une console
d'administration sans authentification derrière un Ingress serait cohérent avec
le point précédent — c'est-à-dire une mauvaise idée.

**Les champs ECS sont indexés en clés plates** (`log.level`, `service.name`)
alors que Filebeat produit par ailleurs un objet `log` imbriqué
(`log.file.path`). Les deux coexistent et restent interrogeables, mais un filtre
Kibana sur `log.*` demande de savoir lequel des deux on vise. Les tableaux de
bord fonctionnent malgré tout — vérifié, `k8s/elk/dashboards/README.md` — et un
pipeline d'ingestion reste souhaitable pour la propreté, pas nécessaire.

**Aucune rétention.** Sans ILM, les données s'accumulent jusqu'à ce que le PVC
de 5 Gio se remplisse. Sur un poste de développement c'est sans conséquence
immédiate ; en revanche les seuils disque d'Elasticsearch (85 / 90 / 95 %)
mettent l'index en lecture seule bien avant que le volume soit plein.

**Aucune métrique de ressources.** Ni CPU, ni mémoire : `kubectl top` répond
`Metrics API not available`, faute de `metrics-server`. Les `resources` des
Deployments restent des estimations. Les traces (§10) apportent la latence et
le débit de l'API, pas la consommation des pods ; et les métriques de la JVM
que l'agent pourrait envoyer sont coupées (`OTEL_METRICS_EXPORTER=none`).

**Les traces n'ont pas de recul.** Seul du trafic provoqué les a traversées
dans le cluster ; aucune latence en service n'est relevée (§10.4). Leurs autres
limites sont au §10.7.

**L'alerting ne notifie personne hors de Kibana, et ne se surveille pas
lui-même.** Ses limites sont au §11.5.

**La production n'est observée que par ses traces.** Filebeat ne collecte que
`microcrm-staging` : les tableaux de bord et les cinq règles fondés sur les
logs ne voient pas `microcrm-production`.

**Presque rien n'est automatisé.** Aucun job de CI ne déploie ni ne teste cette
stack, ni n'installe ses règles d'alerte. `dora-metrics` calcule les indicateurs
sans les injecter dans Elasticsearch (§9.5) ; les rapports de sécurité publiés
par `trivy-fs` et `package-*` ne sont pas envoyés à `microcrm-security` par un
job.

## 13. Rejouer

```shell
# 1. Le namespace, son quota et ses limites (Terraform possède le contenant)
cd terraform/environments/logging && terraform apply

# 2. La clé de chiffrement de Kibana, une fois par cluster : le Secret
#    `kibana-encryption-key`, valeur aléatoire, jamais écrite dans le dépôt
scripts/monitoring/install_alerting.py --secret

# 3. La stack
kubectl apply -k k8s/elk -n logging
kubectl -n logging rollout status deployment/elasticsearch --timeout=300s
kubectl -n logging rollout status deployment/kibana --timeout=420s

# 4. Vérifier que la collecte fonctionne
kubectl -n logging exec deploy/elasticsearch -- \
  curl -s 'localhost:9200/_cat/indices?v'

# 5. Vérifier qu'un log du back est bien arrivé, décodé
kubectl -n logging exec deploy/elasticsearch -- curl -s -X POST \
  'localhost:9200/microcrm-logs*/_search?size=1' -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"kubernetes.container.name":"back"}}}'

# 6. Kibana et Elasticsearch, joignables depuis le poste
kubectl -n logging port-forward svc/kibana 5601:5601 &
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &

# 7. Les règles d'alerte : modèle d'index, puis les huit règles
scripts/monitoring/install_alerting.py            # crée ou met à jour
scripts/monitoring/install_alerting.py --etat     # état de chaque règle

# 8. Les cinq tableaux de bord
for f in microcrm dora securite disponibilite alertes; do
  curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
    -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/$f.ndjson
done
```

L'étape 1 crée aussi la `NetworkPolicy` d'APM Server, et l'étape 3 son
Deployment. La vérification des traces est au §10.6.

⚠️ **L'ordre des étapes 2 et 3 compte, et l'étape 7 le vérifie.** `--secret`
redémarre Kibana, ce qui coupe tout `port-forward` ouvert vers lui : c'est la
raison pour laquelle la création du Secret et l'installation des règles sont
deux commandes distinctes. Sans clé permanente, `install_alerting.py` refuse
d'installer et dit quoi lancer. Les tableaux de bord `dora` et `securite`
restent vides tant que leurs index ne sont pas alimentés (§9.5, et
`collect_security.py` dans `SCRIPTS.md`).

⚠️ Le back doit tourner avec le profil `container` (clé
`SPRING_PROFILES_ACTIVE` de la ConfigMap, §3) pour produire du JSON. Sans lui,
les documents arrivent quand même, mais sans champ exploitable.
