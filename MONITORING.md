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

Spring Boot 3.2.5 n'a pas le _structured logging_ natif — il est arrivé en 3.4.
La bascule passe donc par un encodeur Logback,
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

## 9. Ce qui n'est pas fait

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

## 10. Rejouer

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
