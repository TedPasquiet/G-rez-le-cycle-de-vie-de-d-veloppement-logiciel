# Alerting — règles d'alerte Kibana, versionnées

Huit règles d'alerte couvrant la disponibilité, la performance et la sécurité
de MicroCRM. Le raisonnement d'ensemble est dans `MONITORING.md` §11.

**Le livrable n'est pas une liste dans _Stack Management > Rules_, ce sont les
fichiers de `rules/`.** Une règle créée à la souris vit dans l'index `.kibana`
d'un pod et disparaît avec lui — et une alerte disparue ne prévient pas qu'elle
a disparu. Même raisonnement que pour les tableaux de bord (`../dashboards/`).

## Ce qu'il y a ici

| Fichier                                  | Rôle                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------- |
| `rules/<identifiant>.json`               | une règle ; le nom du fichier est son identifiant dans Kibana             |
| `index-template.json`                    | types des champs de l'index `microcrm-alerts`                             |
| `../kibana-config.yaml`                  | les deux connecteurs préconfigurés (`xpack.actions.preconfigured`)        |
| `../kibana-deployment.yaml`              | la clé de chiffrement, lue dans un Secret qui n'est pas dans le dépôt     |
| `../dashboards/alertes.ndjson`           | le tableau de bord « suivi des alertes » (8 objets)                       |
| `scripts/monitoring/install_alerting.py` | installation idempotente (modèle d'index + règles), et création du Secret |

## Le mécanisme retenu, et pourquoi

**Règles Kibana natives, type `.es-query` en ES|QL.** Sur cette stack (8.19.7,
licence `basic`, `xpack.security.enabled: false`), elles s'exécutent sans clé
d'API ni utilisateur. ElastAlert n'est donc pas nécessaire — un composant de
moins à faire tourner et à mettre à jour.

Trois réglages sont nécessaires, et chacun est un piège si on l'ignore :

**1. La clé de chiffrement.** Sans `xpack.encryptedSavedObjects.encryptionKey`,
Kibana tire une clé au hasard à chaque démarrage : `GET /api/alerting/_health`
renvoie `"has_permanent_encryption_key": false` et `GET /api/actions/connectors`
répond **500**. La clé est un secret et ce dépôt est public : elle n'est écrite
dans aucun fichier. Elle vit dans le Secret `kibana-encryption-key`, créé par
`install_alerting.py --secret` avec une valeur aléatoire, et le Deployment la
lit par `secretKeyRef` (`optional: true`, pour qu'un `kubectl apply -k` sur un
cluster neuf donne tout de même un Kibana qui démarre).

⚠️ La clé ne survit pas à un `minikube delete`. Sur un cluster reconstruit, une
nouvelle clé est tirée et les règles sont réinstallées depuis les fichiers —
rien n'est perdu, précisément parce que les règles ne vivent pas dans
l'instance.

**2. Les connecteurs.** La licence `basic` n'ouvre que deux types de
notification, relu sur l'instance par `GET /api/actions/connector_types` :

| Type          | Licence minimale | Utilisable ici |
| ------------- | ---------------- | -------------- |
| `.index`      | basic            | oui            |
| `.server-log` | basic            | oui            |
| `.webhook`    | gold             | **non**        |
| `.slack`      | gold             | **non**        |
| `.email`      | gold             | **non**        |

Chaque règle déclenche donc deux actions : un document dans l'index
`microcrm-alerts` (connecteur `microcrm-alerts-index`) et une ligne dans le
journal du pod Kibana (connecteur `microcrm-alerts-journal`). Les deux
connecteurs sont **préconfigurés** dans `kibana-config.yaml` : identifiant fixe,
présents dès le démarrage, non modifiables depuis l'interface.

**3. ES|QL plutôt que le seuil sur index.** Le type `.index-threshold` ne sait
calculer que `count`, `avg`, `min`, `max`, `sum` : pas de percentile, donc pas de
p95. En ES|QL la règle se déclenche dès que la requête renvoie une ligne ; le
seuil est donc écrit **dans la requête** (`| WHERE valeur >= 2`), ce qui permet
de la rejouer telle quelle dans _Dev Tools_ pour comprendre une alerte.

Chaque requête renvoie deux colonnes, `valeur` et `detail`, recopiées dans le
document d'alerte.

## Installer / réinstaller

```shell
# 1. Une fois par cluster : la clé de chiffrement (redémarre Kibana)
scripts/monitoring/install_alerting.py --secret

# 2. Les connecteurs : ils sont dans kibana-config.yaml
kubectl apply -k k8s/elk -n logging
kubectl -n logging rollout status deployment/kibana --timeout=420s

# 3. Les règles
kubectl -n logging port-forward svc/kibana 5601:5601 &
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &
scripts/monitoring/install_alerting.py            # crée ou met à jour
scripts/monitoring/install_alerting.py --etat     # état de chaque règle

# 4. Le tableau de bord
curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
  -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/alertes.ndjson
```

Le script est idempotent : règle absente → créée (`POST`), règle présente → mise
à jour sur place (`PUT`). Vérifié le 2026-10-02 : première exécution « 8 règles
créées », seconde « 8 règles mises à jour », `GET /api/alerting/rules/_find`
renvoie toujours `total: 8`. L'import du tableau de bord, objets préalablement
supprimés, renvoie `{"success":true,"successCount":8}`.

`KIBANA_URL` et `ELASTICSEARCH_URL` changent les adresses par défaut. Le script
refuse d'installer tant que la clé n'est pas permanente, et le dit.

Pour modifier une règle : éditer le fichier, relancer le script. Une retouche
faite dans l'interface est écrasée à la prochaine installation — c'est voulu.

## Les huit règles

Toutes s'évaluent **chaque minute**. Les statistiques qui justifient les seuils
ont été relevées le 2026-10-02 dans Elasticsearch.

### Ce que les données permettent, et ce qu'elles ne permettent pas

À lire avant le tableau, parce que cela borne tout le reste :

- **Filebeat ne collecte que `microcrm-staging`.** Aucune règle fondée sur les
  logs ne voit la production.
- **Le journal d'accès du front ne contient que les sondes de Kubernetes** en
  temps normal (41 430 requêtes en 7 jours, toutes `kube-probe`, toutes `GET /`,
  toutes en 200). C'est un battement de cœur régulier — 18 requêtes par minute —
  ce qui en fait un bon signal de disponibilité.
- **Le front ne renvoie jamais de 4xx** : c'est une SPA, tout chemin inconnu
  renvoie 200. Un « pic de 404 » ne peut pas exister côté front. En revanche le
  chemin demandé est journalisé (`caddy.request.uri`), et c'est lui qu'on
  surveille.
- **Le back ne journalise pas ses accès**, et ne journalise rien pour un 400 ou
  un 404. Il journalise une ligne `WARN` avec `error.type` quand une requête se
  termine en exception — donc en 500.
- **L'application n'a pas d'authentification** : un 401 ou un 403 ne peut pas se
  produire. La règle « sécurité » côté API compte donc les 4xx en général.
- **Les trois règles « traces APM » regroupent par `service.environment`.** Les
  back de staging et de production émettent des traces : ces règles
  surveillent les deux environnements. Leurs seuils, en revanche, sont calés sur
  des traces d'essai lancées sur le poste.

### Disponibilité

| Règle                        | Source     | Fenêtre | Seuil                 |
| ---------------------------- | ---------- | ------- | --------------------- |
| `dispo-front-muet`           | logs Caddy | 3 min   | moins de 1 requête    |
| `dispo-back-redemarrages`    | logs back  | 15 min  | 2 démarrages ou plus  |
| `dispo-back-echecs-requetes` | logs back  | 5 min   | 1 exception ou plus   |
| `dispo-api-5xx`              | traces APM | 5 min   | 1 réponse 5xx ou plus |

**`dispo-front-muet`** — le front de staging ne sert plus rien, ou Filebeat ne
collecte plus. _Pourquoi ce seuil :_ les sondes produisent 90 lignes par tranche
de 5 minutes (médiane sur 7 jours), soit 54 attendues en 3 minutes. Zéro ligne
n'est donc jamais un creux de trafic, c'est une panne. _Limite :_ la règle ne
distingue pas « front arrêté » de « collecte interrompue » ; et sur un poste,
la mise en veille de la machine produit au réveil une alerte exacte mais sans
intérêt (rien n'a été servi, en effet).

**`dispo-back-redemarrages`** — compte les lignes `Starting MicroCRMApplication`.
_Pourquoi ce seuil :_ 12 démarrages en 47 jours, jamais plus d'un par quart
d'heure sauf une fois. Un déploiement normal en produit un seul. On compte
`Starting…` et non `Started…` pour voir aussi un back qui meurt avant d'avoir
fini de démarrer. _Limite :_ un back arrêté sans redémarrer (`replicas: 0`)
n'écrit rien et n'est **pas** détecté par cette règle : le back n'a pas de
battement de cœur dans ses logs. `dispo-api-5xx` ne le voit pas non plus — un
back absent ne produit pas de trace.

**`dispo-back-echecs-requetes`** — lignes du back portant `log.level: ERROR` ou
un `error.type`. _Pourquoi ce seuil :_ aucune ligne de ce genre en 47 jours
avant l'essai (374 lignes avec un niveau : 325 INFO, 49 WARN, 0 ERROR ; les WARN
de démarrage n'ont pas d'`error.type`). Chaque occurrence est une requête
terminée en 500. _Défaut applicatif rendu visible :_ `GET /persons/abc` renvoie
500 (`ConversionFailedException`) au lieu de 400 ; il n'est pas corrigé.

**`dispo-api-5xx`** — transactions HTTP en 5xx, par `service.environment`.
Même signal que la précédente, vu par les traces : c'est elle qui couvre la
production. _Pourquoi ce seuil :_ 0 réponse 5xx sur les 401 transactions
relevées avant l'essai.

### Performance

| Règle            | Source     | Fenêtre | Seuil                                      |
| ---------------- | ---------- | ------- | ------------------------------------------ |
| `perf-front-p95` | logs Caddy | 5 min   | p95 > 100 ms, sur 20 requêtes au moins     |
| `perf-api-p95`   | traces APM | 5 min   | p95 > 250 ms, sur 20 transactions au moins |

**`perf-front-p95`** — `caddy.duration`, en secondes. _Pourquoi ce seuil :_ sur
624 tranches de 5 minutes (7 jours), le p95 médian est de 1,54 ms et 90 % des
tranches sont sous 2,75 ms. 100 ms, c'est 65 fois la médiane. 12 tranches le
dépassent ; avec le plancher de 20 requêtes il en reste 4, toutes à des moments
où la machine était saturée (la pire : p95 de 388 ms sur 75 requêtes). Le
plancher écarte les tranches de quelques requêtes au réveil de la machine, où un
seul point lent fait le percentile. _Limite :_ c'est la latence du serveur de
fichiers statiques, mesurée surtout sur les sondes ; elle ne dit rien de l'API.

**`perf-api-p95`** — `transaction.duration.us`, par environnement. _Pourquoi ce
seuil :_ sur 401 transactions relevées avant l'essai, p95 de 5,6 ms et 17,4 ms
selon l'environnement, maximum de 97 ms. 250 ms, c'est 14 fois le p95 le plus
élevé et 2,5 fois le maximum. ⚠️ L'échantillon est petit et vient de conteneurs
lancés sur le poste, pas d'un trafic réel : **ce seuil est à recaler** sur
quelques jours de traces de staging.

### Sécurité

| Règle                          | Source     | Fenêtre | Seuil                   |
| ------------------------------ | ---------- | ------- | ----------------------- |
| `secu-front-chemins-sensibles` | logs Caddy | 5 min   | 1 requête ou plus       |
| `secu-api-rafale-4xx`          | traces APM | 5 min   | 20 réponses 4xx ou plus |

**`secu-front-chemins-sensibles`** — requêtes dont le chemin contient `.env`,
`.git`, `.aws`, `..`, `%2e%2e`, `etc/passwd`, `id_rsa`, `wp-`, `phpmyadmin`,
`.php`, `cgi-bin` ou `actuator` : la signature d'un balayage automatique.
_Pourquoi ce seuil :_ sur 68 493 requêtes en 30 jours, le seul chemin demandé
était `/`. L'application Angular n'a aucune route de ce genre ; une seule
requête suffit à dire que quelqu'un cherche. _Limites :_ le front répond 200 à
ces requêtes (SPA) — l'alerte signale une **tentative**, pas une fuite ; la
liste de motifs est courte et ne remplace pas un WAF ; derrière un Ingress
exposé à Internet, ce seuil de 1 sonnerait en permanence et devrait être relevé.

**`secu-api-rafale-4xx`** — réponses 400 à 499 de l'API, par environnement :
énumération d'identifiants, requêtes forgées. _Pourquoi ce seuil :_ le trafic
nominal relevé n'en produit aucune (0 sur 98 transactions) ; une énumération en
produit des dizaines (40 et 64 observées en cinq minutes). 20 laisse passer
quelques liens périmés. _Limite :_ ce seuil repose sur peu de données, et le 4xx
est un signal indirect — l'application n'ayant pas d'authentification, il
n'existe ni 401 ni 403 à compter.

## Preuve de déclenchement — 2026-10-02

Les huit règles ont été déclenchées puis se sont rétablies. Heures UTC,
relevées dans l'index `microcrm-alerts` :

| Règle                          | Provoquée par                                                                  | Déclenchée | Valeur   | Rétablie |
| ------------------------------ | ------------------------------------------------------------------------------ | ---------- | -------- | -------- |
| `dispo-back-echecs-requetes`   | `GET /persons/abc` sur le back de staging (500)                                | 19:37:35   | 1        | 19:40:35 |
| `dispo-api-5xx`                | la même requête sur un back instrumenté lancé sur le poste                     | 19:37:35   | 1        | 19:40:35 |
| `dispo-back-redemarrages`      | deux `kubectl rollout restart deploy/back -n microcrm-staging`                 | 19:38:38   | 3        | 19:53:39 |
| `secu-api-rafale-4xx`          | 60 `GET /persons/<id inexistant>` sur le back instrumenté                      | 19:38:47   | 64       | 19:43:44 |
| `secu-front-chemins-sensibles` | 8 requêtes (`/.env`, `/.git/config`, `/wp-login.php`…) sur le front de staging | 19:38:50   | 8        | 19:43:50 |
| `perf-api-p95`                 | back instrumenté bridé à 0,05 CPU (`docker update`)                            | 19:40:41   | 269,2 ms | 19:44:41 |
| `perf-front-p95`               | front de staging bridé à 10 m CPU (redimensionnement à chaud) sous charge      | 19:45:44   | 909,1 ms | 19:51:45 |
| `dispo-front-muet`             | `kubectl scale deploy/front --replicas=0 -n microcrm-staging`                  | 19:50:39   | 0        | 19:51:39 |

Pour ne pas sur-lire ce tableau :

- Les trois règles « traces APM » sont prouvées sur un conteneur lancé sur le
  poste (`service.environment: demo-alerting`), pas sur un pod du cluster ;
  l'essai n'a pas été refait sur les back déployés.
- `dispo-back-redemarrages` affiche 3 et non 2 parce que `minikube start` avait
  lui-même démarré le back douze minutes plus tôt.
- Le front ne peut pas être ralenti par un client lent (le `port-forward`
  absorbe la lenteur) : il faut lui retirer du CPU. Sa limite a été remise à
  200 m ensuite.
- Staging a été rendu à son état initial : `front` et `back` à 1 replica, mêmes
  images. La production n'a été lue qu'en lecture.

Captures : `docs/captures/kibana-alertes-liste-des-regles-2026-10-02.png` et
`docs/captures/kibana-alertes-suivi-declenchements-2026-10-02.png`.

## Rejouer un déclenchement

```shell
# Sécurité — immédiat et sans effet de bord
kubectl -n microcrm-staging port-forward svc/front 8080:80 &
for chemin in /.env /.git/config /wp-login.php; do curl -s -o /dev/null "http://127.0.0.1:8080$chemin"; done

# Disponibilité — une exception du back
kubectl -n microcrm-staging port-forward svc/back 8081:8080 &
curl -s -o /dev/null http://127.0.0.1:8081/persons/abc

# Disponibilité — front muet (staging uniquement ; compter 4 minutes)
kubectl -n microcrm-staging scale deploy/front --replicas=0
kubectl -n microcrm-staging scale deploy/front --replicas=1

# Lire le résultat, une à deux minutes plus tard
curl -s 'http://127.0.0.1:9200/microcrm-alerts/_search?sort=@timestamp:desc&size=5'
kubectl -n logging logs deploy/kibana | grep server-log
```

Pour comprendre pourquoi une règle a sonné, copier sa requête
(`params.esqlQuery.esql`) dans _Dev Tools_ en ajoutant la fenêtre :
`POST _query?format=txt` avec `… | WHERE @timestamp > NOW() - 5 minutes | …`.

## L'index `microcrm-alerts`

Un document par **changement d'état**, pas par évaluation : une alerte qui dure
dix minutes écrit deux lignes (`declenchee`, puis `retablie`).

| Champ        | Type    | Contenu                                    |
| ------------ | ------- | ------------------------------------------ |
| `@timestamp` | date    | heure d'envoi, posée par le connecteur     |
| `regle_id`   | keyword | identifiant = nom du fichier               |
| `regle`      | keyword | nom lisible                                |
| `famille`    | keyword | `disponibilite`, `performance`, `securite` |
| `severite`   | keyword | `critique`, `haute`, `moyenne`             |
| `statut`     | keyword | `declenchee` ou `retablie`                 |
| `valeur`     | float   | valeur mesurée ; absente au rétablissement |
| `unite`      | keyword | unité de `valeur`                          |
| `seuil`      | keyword | le seuil, en clair                         |
| `detail`     | text    | précision calculée par la requête          |

## Ce que cet alerting ne fait pas

**Il ne prévient personne en dehors de Kibana.** Une alerte s'écrit dans un
index et dans un journal : il faut ouvrir le tableau de bord pour la voir. Un
webhook exigerait la licence `gold`. Le pont vers `scripts/ci/notify.py`
(`NOTIFY_WEBHOOK_URL`) n'est pas fait : il demanderait un petit programme qui
relit `microcrm-alerts` et pousse les nouvelles lignes — c'est la suite logique.

**Il ne se surveille pas lui-même.** Si Kibana ou Elasticsearch tombe, les
règles ne s'évaluent plus et aucune alerte ne le dit. Un tableau de bord vide se
lit alors comme « tout va bien ».

**La production n'est couverte que par les trois règles sur traces.** Les cinq
règles fondées sur les logs ne voient que staging.

**Aucune métrique d'infrastructure** : ni CPU, ni mémoire, ni disque, ni état
des pods. Un `CrashLoopBackOff` n'est vu que par ses effets (redémarrages
journalisés, front muet). Le remplissage du PVC d'Elasticsearch n'est pas
surveillé.

**Aucune rétention** sur `microcrm-alerts` : comme le reste de la stack, sans
ILM.

**L'installation n'est pas automatisée** : aucun job de CI ne lance
`install_alerting.py`. Les tests (`scripts/tests/run_tests.sh`) contrôlent les
fichiers de règles et le script, pas une instance.
