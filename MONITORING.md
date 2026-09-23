# Supervision — la stack ELK

Centralisation des logs de MicroCRM : Elasticsearch, Kibana et Filebeat sur le
cluster local. Ce document dit ce que la chaîne fait, ce qu'elle ne fait pas, et
les pièges qu'il a fallu écarter pour qu'elle fonctionne.

**État : la chaîne est déployée et vérifiée de bout en bout.** Un log écrit par
le pod `back` se retrouve dans Elasticsearch, décodé et enrichi.

| Vérification                              | Résultat                                                              |
| ----------------------------------------- | --------------------------------------------------------------------- |
| Rollout Elasticsearch / Kibana / Filebeat | les trois `Running`                                                   |
| Documents indexés                         | 50, dont **36 du conteneur `back`**                                   |
| Provenance                                | **100 % `microcrm-staging`** — aucun projet voisin collecté           |
| Champs ECS décodés                        | `log.level`, `log.logger`, `service.name`, `process.thread.name`      |
| Métadonnées Kubernetes                    | `kubernetes.pod.name`, `kubernetes.namespace`, `container.image.name` |

## 1. Le manque que ça comble

`QUALITY.md` §6 l'annonçait sans détour : les contrôles du projet agissent tous
**avant** le déploiement. Une fois l'application en marche, plus rien ne disait
si elle répondait ni ce qu'elle racontait. Le seul moyen de lire un log était
`kubectl logs`, c'est-à-dire un pod à la fois, sans historique — un pod
redémarré emportait ses logs avec lui.

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

## 3. Les logs applicatifs : deux formats, un profil

Le _structured logging_ natif de Spring Boot n'est arrivé qu'en 3.4, après le
choix fait ici sur la 3.2.5. La bascule passe donc par un encodeur Logback,
`co.elastic.logging:logback-ecs-encoder:1.7.0`, choisi plutôt que l'encodeur
Logstash parce qu'il émet directement le schéma qu'attendent Elasticsearch et
Kibana ; l'autre aurait imposé de renommer chaque champ, donc de maintenir une
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
l'assertion d'équivalence de `scripts/tests/validate_k8s.sh` échouerait en
nommant le champ si l'un des deux était oublié.

## 4. Filebeat ne collecte pas tout, et c'est délibéré

**Ce cluster n'est pas dédié à MicroCRM.** Il héberge aussi les namespaces `dev`
et `staging` (projets `olympic-games-app` et `workshop-organizer`) et quatre pods
dans `default`. Un Filebeat non filtré y ingérerait les logs de projets tiers :
ce n'est pas une question de volume, c'est une question de périmètre.

L'autodiscover ne collecte donc que le namespace de l'application, et ce
namespace est une valeur de configuration, pas une chaîne enfouie dans le YAML.
Vérifié après coup : sur 50 documents, **100 % viennent de `microcrm-staging`**.

**Deux décodages JSON, et un seul à la racine.** Le back produit de l'ECS, décodé
à la racine. Le front (Caddy) écrit lui aussi du JSON, mais **non-ECS**, dont les
champs portent les mêmes noms que ceux de Filebeat sans avoir la même forme. Un
décodage appliqué à tous les conteneurs faisait rejeter ses documents :

```
document_parsing_exception: object mapping for [file] tried to parse field [file] as object
```

Une collision de mapping est **irréversible** : une fois le champ typé dans
l'index, aucun document contradictoire n'y entrera plus. Le journal du front est
donc décodé sous le préfixe `caddy`, ce qui isole ses champs de l'espace ECS et
laisse les deux formats cohabiter.

## 5. La latence : d'où elle vient, et pourquoi elle n'existait pas

Il n'y avait, au départ, **aucune donnée de latence dans toute la chaîne**. Les
logs applicatifs du back portent ce que l'application raconte, pas le temps
qu'elle met ; et le Caddyfile n'avait aucune directive `log`, donc le front
n'écrivait que ses journaux internes de démarrage et de maintenance TLS. Un
écran « latence » construit là-dessus aurait été décoratif.

Le journal d'accès de Caddy a donc été activé (`front/Caddyfile`). C'est la
seule source qui voit réellement passer le trafic, et elle porte les trois
mesures d'un coup : `caddy.status`, `caddy.duration` et le simple comptage.

Mesuré après 105 requêtes :

```
p50 = 0,14 ms     p95 = 1,60 ms     p99 = 3,11 ms
```

⚠️ **C'est la latence vue par le serveur web, pas par l'API.** Caddy sert le
bundle Angular et `/config.json` ; les appels à l'API partent du navigateur vers
un hôte distinct et ne passent pas par lui. Mesurer la latence de l'API
demanderait de l'instrumenter elle-même — c'est le domaine des métriques, pas
des logs.

⚠️ **Le front ne produira quasiment jamais de 4xx.** C'est une application
Angular servie avec `try_files {path} /index.html` : tout chemin inconnu renvoie
`200` avec la page, à charge pour le routeur Angular de décider. Vérifié — 12
requêtes vers des chemins inexistants ont toutes renvoyé `200`. Les erreurs
réelles se lisent donc côté back, dans `log.level`.

## 6. Le dimensionnement, et pourquoi il tient

Point de vigilance explicite du brief : une stack sous-dimensionnée ne démarre
pas. Les chiffres, et la règle qui les gouverne :

| Composant     | requests      | limits         | tas                    |
| ------------- | ------------- | -------------- | ---------------------- |
| Elasticsearch | 500m / 1536Mi | 2 CPU / 2Gi    | 1 Gio (`ES_JAVA_OPTS`) |
| Kibana        | 200m / 768Mi  | 1 CPU / 1536Mi | 768 Mio                |
| Filebeat      | 100m / 128Mi  | 500m / 256Mi   | —                      |

**La limite mémoire vaut le double du tas.** Un conteneur JVM dont la limite
égale le tas est tué par l'OOM killer au premier pic hors-tas — metaspace, cache
de code, piles de threads. C'est la cause la plus banale d'une stack ELK qui
« ne démarre pas » sans message utile.

Le namespace porte un `ResourceQuota` créé par Terraform
(`terraform/environments/logging/`), calé sur le **pic d'un déploiement** et non
sur l'état stable. Le calcul du pic diffère de celui des environnements
applicatifs, parce que les trois composants n'ont pas la même stratégie :

- **Elasticsearch est en `Recreate`**, pas en `RollingUpdate`. Son PVC est
  `ReadWriteOnce` et son répertoire de données verrouillé par `node.lock` : un
  second pod resterait bloqué en `ContainerCreating`, pendant que l'ancien reste
  en place — un déploiement qui ne finit jamais. Son pic vaut donc **1 pod**.
- Kibana surge à 2. Filebeat est un DaemonSet : il remplace sans ajouter.

**Vérifié en conditions réelles**, en relançant Kibana et en observant le quota
pendant le rollout :

```
$ kubectl -n logging describe quota logging-quota      # pendant le rollout
limits.memory    5376Mi  6Gi
requests.memory  3200Mi  4Gi
pods             4       12
```

Ce sont exactement les valeurs calculées dans `terraform.tfvars`, au mégaoctet
près. C'est aussi la première fois qu'un quota posé par Terraform est confronté à
une charge réelle — ce que `TERRAFORM.md` §9.4 listait comme non vérifié.

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

Six panneaux, assemblés en un tableau de bord : volume par conteneur, latence
(p50/p95/p99), erreurs applicatives, erreurs HTTP, répartition des statuts, et
une table des logs récents.

**Le livrable n'est pas « des écrans dans Kibana », c'est un fichier.** Un
tableau de bord qui n'existe que dans une instance disparaît avec elle — et
celle-ci tourne sur un `emptyDir` de poste de développement. Les huit objets
sauvegardés sont donc exportés dans `k8s/elk/dashboards/microcrm.ndjson`, vue de
données comprise : un export qui l'oublierait produirait à la réimportation des
panneaux vides et un message obscur.

Vérifié en supprimant d'abord les objets de l'instance, pour que le test soit
froid et non un simple écrasement :

```
$ curl -X POST '…/api/saved_objects/_import?overwrite=true' \
    -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/microcrm.ndjson
{"success": true, "successCount": 8, "warnings": []}
```

Et chaque panneau a été confronté à la même agrégation jouée directement contre
Elasticsearch : mêmes chiffres des deux côtés, y compris la latence après
conversion des secondes en millisecondes.

⚠️ **L'unité de `caddy.duration` est déclarée dans la vue de données**
(`fieldFormatMap`, secondes → millisecondes), pas dans une formule de chaque
panneau. Un panneau ajouté demain en hérite ; c'est aussi ce qui rend la vue de
données indispensable à l'export.

⚠️ **Un NDJSON écrit à la main ne s'importe pas.** Sans `typeMigrationVersion`,
Kibana rejoue toute la chaîne de migration 7.x → 8.x et échoue sur
`Cannot read properties of undefined (reading 'layers')`. Les objets doivent
être créés par l'API puis exportés — jamais rédigés à la main. C'est écrit dans
`k8s/elk/dashboards/README.md`, avec la commande de régénération.

## 9. Les métriques DORA

Les quatre indicateurs DORA sont calculés par `scripts/ci/collect_dora.py`, en
Python standard et sans aucune dépendance — même règle que le reste de
`scripts/ci/`, parce que le job tourne dans une image qui n'a pas `pip install`.

**Pourquoi un collecteur maison.** Les métriques DORA natives de GitLab sont
réservées aux offres payantes. Sur le Free Tier, il faut les calculer soi-même
depuis l'API — et le projet est mesurable sans jeton : le dépôt GitHub se
miroite vers un projet GitLab **public**, où le pipeline tourne réellement.

### 9.1 Ce que les chiffres disent, et il faut l'entendre

Mesuré le 2026-09-23, sur les 50 pipelines des 30 derniers jours :

| Indicateur                            | Valeur                           | Observations |
| ------------------------------------- | -------------------------------- | ------------ |
| Fréquence de déploiement              | **0,1667** par jour              | 5            |
| Délai de mise en production (médiane) | **1,38 h** (min 0,64 / max 4,87) | 5            |
| Temps de rétablissement (médiane)     | **2,14 h** (min 0,09 / max 4,18) | 2            |
| Taux d'échec des changements          | **66,67 %**                      | 9            |

**La chaîne aboutit depuis le 2026-09-22.** Neuf jobs de déploiement ont
réellement tourné sur la fenêtre, cinq ont réussi, et deux rollbacks ont été
joués. Staging et production tournent aujourd'hui avec des images du registry
GitLab, posées par la CI et non à la main depuis le poste.

Ce n'est pas le mécanisme qui a changé — il n'a pas bougé — mais une contrainte
et trois défauts :

- **Un runner auto-hébergé** a été enregistré sur le poste. Le Free Tier n'est
  plus consommé du tout, donc `ci_quota_exceeded` ne peut plus arrêter un
  pipeline. C'est ce qui a rendu les trois défauts suivants observables : ils
  étaient là avant, aucun job n'allait assez loin pour les rencontrer.
- **`deploy-*` recevait un kubeconfig par variable de projet**
  (`KUBECONFIG: $KUBE_CONFIG`), lequel désigne le serveur d'API en `127.0.0.1` —
  dans un conteneur de job, c'est le conteneur lui-même, donc une adresse
  structurellement injoignable. Ces jobs passent maintenant par le tunnel de
  l'agent GitLab, comme `terraform-apply-*` le faisait déjà.
- **Le RBAC de l'agent ne couvrait pas les objets applicatifs.** Il a été élargi
  aux Deployments, Services, Ingress, ConfigMaps et Secrets, avec un
  resserrement volontaire sur les Secrets : ni `list`, ni `watch`, ni `delete`.
- **`$STAGING_NAMESPACE` n'était pas définie côté GitLab**, et le job déployait
  dans `default` en silence. Le garde-fou `exige_namespace` fait désormais
  échouer le job — un déploiement qui atterrit ailleurs qu'annoncé est pire
  qu'un déploiement qui n'a pas lieu.

⚠️ **Ces chiffres n'ont pas de valeur statistique, et il faut le dire avant de
les commenter.** Un taux d'échec sur 9 tentatives, un MTTR sur 2 observations :
ce sont des faits, pas des tendances. Les cinq déploiements réussis — un tous
les six jours en moyenne — sont en réalité concentrés sur deux journées
consécutives, celles où la chaîne a été débloquée. Quant au délai de mise en
production de 1,38 h, il mesure surtout l'intervalle entre un commit et le clic
qui déclenche le déploiement : les deux jobs restent `when: manual`.

Les onze jobs retenus, dans l'ordre :

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
```

Le rollback de production a donc été exercé pour de bon, puis suivi d'un
redéploiement : la production est en révision 4, sur l'image `9f4168b3`.

### 9.2 ⚠️ Zéro mesuré et absence de donnée ne sont pas la même chose

C'est la règle qui gouverne tout le collecteur, et la seule qui puisse le rendre
utile plutôt que décoratif. Elle ne se voit plus dans la sortie d'aujourd'hui —
les quatre indicateurs ont une valeur — mais c'est elle qui a tenu pendant les
deux mois où le projet n'avait rien déployé :

- `deployment_frequency` valait alors **`0.0`** : c'était une mesure. Zéro
  déploiement avait bien eu lieu, sur une fenêtre connue, après sept tentatives.
- `lead_time_for_changes` valait **`null`**, accompagné de sa raison : il
  n'existait aucune arrivée en production vers laquelle mesurer un délai.

Rendre le second en `0` aurait affiché un délai de mise en production de zéro
heure, c'est-à-dire **la performance parfaite** — là où il n'y avait simplement
jamais eu de mise en production. Un test de `run_tests.sh` échoue si un
indicateur sans donnée se met à ressortir en `0`, et il n'a aucune raison de
partir : le cas se reproduit dès qu'on interroge une fenêtre sans déploiement.

### 9.3 Comment un rollback est compté, et la limite qu'on assume

Un déploiement réussi puis annulé par un rollback compte comme un **échec**.
C'est la définition DORA du taux d'échec des changements : un changement qui a
dégradé la production. Ces cas sont comptés à part dans la sortie, pour qu'on
puisse les distinguer d'un job simplement rouge :

```json
"details": { "tentatives": 9, "echecs_directs": 4, "reussites_annulees": 2 }
```

Le collecteur retient par ailleurs les jobs en `success` **et** en `failed`
(`STATUTS_EXECUTES`, ligne 103 de `scripts/ci/collect_dora.py`) : un job qui a
tourné compte, quel que soit son verdict. `manual`, `skipped`, `created` et
`canceled` sont exclus — ils décrivent des déploiements qui n'ont pas eu lieu.

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
le taux d'échec de **66,67 % à 55,56 %** (5 échecs sur 9).

**Ce comptage est assumé, pas corrigé**, et le choix se justifie dans un seul
sens. Un collecteur pessimiste surévalue le taux d'échec ; l'erreur inverse
produirait un chiffre flatteur que personne n'aurait les moyens de contredire.
Entre les deux, on garde celui qui ne se vante pas — à la condition stricte
d'écrire ce qu'il rate, ce que fait ce paragraphe. Le corriger reste possible et
demanderait deux choses : lire l'`environment:name` du job de rollback, et ne
retenir que les rollbacks en `success`.

### 9.4 Comment il est testé

Sur des **fixtures**, c'est-à-dire des réponses d'API enregistrées, et pas contre
le réseau : un test qui dépend d'un service tiers échoue les jours où ce service
est lent, et on finit par ne plus le croire.

Deux jeux, et la distinction est délibérée :

- `scripts/tests/fixtures/` — **réel**, enregistré verbatim depuis l'API : les
  44 pipelines et les jobs des 7 pipelines ayant déclenché un déploiement ;
- `scripts/tests/fixtures/dora-scenario-fabrique/` — **fabriqué**, et nommé pour
  qu'on ne s'y trompe pas. Il contient ce que le jeu réel n'offre pas — des
  déploiements réussis — sans quoi les formules du délai et du MTTR ne seraient
  empruntées par aucun test. On ne vérifierait alors qu'une chose : la capacité
  du collecteur à dire « je n'ai rien ».

⚠️ **Les fixtures réelles datent d'avant le 2026-09-22** : rejouées, elles
rendent encore `0,0` déploiement par jour et 100 % d'échec, ce qui est correct
pour la fenêtre qu'elles décrivent. Elles n'ont pas été réenregistrées, et le
jeu fabriqué reste donc nécessaire. Le jour où on les rafraîchira, la sortie de
référence des tests changera avec elles — c'est le prix d'une fixture verbatim,
et il est préférable à celui d'un test qui appelle le réseau.

### 9.5 Rejouer

```shell
# Contre la vraie API, sans jeton (le projet miroir est public)
python3 scripts/ci/collect_dora.py --project 84606666 --days 30

# Hors ligne, sur les fixtures
python3 scripts/ci/collect_dora.py --fixtures scripts/tests/fixtures --days 0

# Injection dans Elasticsearch, pour le tableau de bord
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &
python3 scripts/ci/collect_dora.py --project 84606666 --days 0 \
  --elasticsearch http://127.0.0.1:9200 --es-index microcrm-dora
```

⚠️ **Aucun job de CI n'exécute ce collecteur** — vérifié : aucun fichier de
`.gitlab/ci/` n'appelle `collect_dora.py`. Il se lance à la main. L'obstacle
n'est plus le quota, qui ne s'applique plus depuis que le runner est
auto-hébergé : c'est une évolution du pipeline qui n'a simplement pas été faite.
Elle est inscrite au plan sous A3.3 (`docs/plan-optimisation-release.md`).

## 10. Ce qui n'est pas fait

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
Kibana sur `log.*` demande de savoir lequel des deux on vise. À corriger par un
pipeline d'ingestion le jour où les tableaux de bord seront construits.

**Aucune rétention.** Sans ILM, les données s'accumulent jusqu'à ce que le PVC
de 5 Gio se remplisse. Sur un poste de développement c'est sans conséquence
immédiate ; en revanche les seuils disque d'Elasticsearch (85 / 90 / 95 %)
mettent l'index en lecture seule bien avant que le volume soit plein.

**Rien n'est automatisé.** Aucun job de CI ne déploie ni ne teste cette stack.

## 11. Rejouer

```shell
# 1. Le namespace, son quota et ses limites (Terraform possède le contenant)
cd terraform/environments/logging && terraform apply

# 2. La stack
kubectl apply -k k8s/elk -n logging
kubectl -n logging rollout status deployment/elasticsearch --timeout=300s
kubectl -n logging rollout status deployment/kibana --timeout=300s

# 3. Vérifier que la collecte fonctionne
kubectl -n logging exec deploy/elasticsearch -- \
  curl -s 'localhost:9200/_cat/indices?v'

# 4. Vérifier qu'un log du back est bien arrivé, décodé
kubectl -n logging exec deploy/elasticsearch -- curl -s -X POST \
  'localhost:9200/microcrm-logs*/_search?size=1' -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"kubernetes.container.name":"back"}}}'

# 5. Kibana
kubectl -n logging port-forward svc/kibana 5601:5601
```

⚠️ Le back doit tourner avec le profil `container` pour produire du JSON. Une
image construite avant ce lot journalise en texte : les documents arrivent quand
même, mais sans champ exploitable.
