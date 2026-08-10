# Déploiement Kubernetes

Description de l'infrastructure de déploiement de MicroCRM : les manifestes du
dossier `k8s/`, la façon dont la CI les applique, et ce que cette première
version ne fait pas encore.

**État : les manifestes existent et se construisent. Ils n'ont jamais été
appliqués sur un vrai cluster** — le projet n'en a pas. Tout ce qui suit est
vérifié jusqu'à l'étape que permet un poste de développement : la construction
Kustomize des overlays, le comportement des conteneurs sous les contraintes de
sécurité imposées, et le fonctionnement des sondes de santé. Le reste
(programmation sur des nœuds, Ingress réellement routé, rollout observé) reste à
valider le jour où un cluster sera disponible.

## 1. Le problème que ça résout

Avant ce lot, `scripts/deploy/deploy.sh` savait mettre à jour un déploiement,
mais rien ne savait le **créer**. Le script commence par :

```bash
kubectl -n "$namespace" get deployment "$deployment" >/dev/null 2>&1 \
  || die "Deployment '$deployment' introuvable dans le namespace '$namespace'"
```

Sur un cluster vierge, ce test échoue toujours. Le pipeline s'arrêtait donc à la
première mise en production, et la seule façon d'avancer aurait été de créer les
ressources à la main — c'est-à-dire d'avoir un environnement dont personne ne
peut dire comment il a été construit, ni le reconstruire à l'identique.

C'est exactement ce que l'**infrastructure as code** évite : l'état voulu du
cluster est décrit dans des fichiers versionnés, relus en revue, et appliqués par
la CI. Un environnement perdu se recrée avec une commande.

## 2. Kustomize plutôt que Helm

Les deux outils répondent à la même question — « comment décrire deux
environnements qui se ressemblent à 90 % sans copier-coller les manifestes ? » —
mais pas de la même façon.

| Critère                 | Kustomize                                | Helm                                                           |
| ----------------------- | ---------------------------------------- | -------------------------------------------------------------- |
| Mécanisme               | surcharge de YAML par YAML               | moteur de templates Go sur des fichiers `.tpl`                 |
| Installation            | **intégré à `kubectl`** depuis la 1.14   | binaire supplémentaire à installer et à figer                  |
| Ce qu'on lit            | du Kubernetes valide, dans les deux sens | des gabarits `{{ if }}` qui ne sont du YAML qu'une fois rendus |
| Suivi des installations | aucun état, `kubectl apply` fait foi     | des _releases_ stockées dans le cluster, à gérer               |
| Point fort              | modifier ce qui existe                   | distribuer un composant à des tiers                            |

Le choix se joue sur deux points.

D'abord, **Kustomize est déjà là**. `alpine/kubectl:1.34.2`, l'image déjà figée
dans le pipeline pour le stage `deploy`, sait faire `kubectl apply -k` sans rien
installer. Helm aurait ajouté un outil à épingler, à mettre à jour et à
surveiller, pour un dépôt qui n'a que deux services.

Ensuite, **Helm résout un problème que je n'ai pas**. Sa force est de
_distribuer_ un composant paramétrable à des gens qui ne le connaissent pas :
d'où les `values.yaml`, les conditions, les boucles. Ici les manifestes ne
sortent pas du dépôt et ne servent qu'à une application. Le prix des templates —
du YAML qu'on ne peut plus relire directement, ni valider sans le rendre —
n'achèterait rien.

Un troisième argument est plus discret mais compte en revue : avec Kustomize,
**un overlay est un manifeste Kubernetes normal**. Une différence entre staging
et production se lit comme du Kubernetes, pas comme une expression de template.

## 3. L'arborescence

```
k8s/
  base/                     # la forme de l'application, commune à tous
    kustomization.yaml
    configmap.yaml          # MICROCRM_CORS_ALLOWED_ORIGINS, FRONT_API_BASE_URL
    back-deployment.yaml    # conteneur `back`, port 8080, sondes actuator
    back-service.yaml       # ClusterIP `back`
    front-deployment.yaml   # conteneur `front`, port 80 (Caddy)
    front-service.yaml      # ClusterIP `front`
    ingress.yaml            # deux hôtes : le front et l'API
  overlays/
    staging/
      kustomization.yaml
      configmap-patch.yaml
      ingress-patch.yaml
    production/
      kustomization.yaml
      configmap-patch.yaml
      ingress-patch.yaml
      back-resources-patch.yaml
```

Il n'y a **pas de `namespace.yaml`** ni de `PersistentVolumeClaim` : les deux
absences sont délibérées et expliquées plus bas (§4 et §8.1).

Deux noms sont **contractuels** et ne peuvent pas changer librement : les
Deployments `back` / `front` et les conteneurs `back` / `front`.
`scripts/deploy/deploy.sh` exécute `kubectl set image deployment/back back=…`,
avec les valeurs de `$APP_BACK_NAME` et `$APP_FRONT_NAME`. Le job `lint-k8s`
vérifie ce contrat à chaque commit (§9).

## 4. Ce qui n'est pas dans le dépôt, et pourquoi

Deux valeurs manquent volontairement aux manifestes.

| Valeur absente            | D'où elle vient                               | Pourquoi pas dans le dépôt                           |
| ------------------------- | --------------------------------------------- | ---------------------------------------------------- |
| Le **namespace**          | `$STAGING_NAMESPACE` / `$PROD_NAMESPACE`      | déjà externalisées, et `PROD_NAMESPACE` est protégée |
| Le **chemin du registry** | `$CI_REGISTRY_IMAGE` + `$CI_COMMIT_SHORT_SHA` | dépend du projet GitLab, et le tag dépend du commit  |

C'est la suite directe de la démarche de [VARIABILISATION.md](VARIABILISATION.md).
Écrire `namespace: microcrm-prod` dans `overlays/production/kustomization.yaml`
aurait remis dans le dépôt une coordonnée d'infrastructure qui venait juste d'en
sortir — et aurait créé une seconde source de vérité, qui finit toujours par
diverger de la première.

La règle est donc : **Kustomize décrit la forme, la CI fournit les coordonnées.**

- Le namespace arrive par la ligne de commande :
  `kubectl apply -k k8s/overlays/staging -n "$STAGING_NAMESPACE"`.
- L'image arrive par `deploy.sh`, juste après (§6).

Conséquence à assumer : le namespace doit **exister avant** le premier
déploiement. Ce n'est pas gênant — sa création est un acte d'administration du
cluster, généralement soumis à des quotas et à des règles d'accès qui ne
relèvent pas du dépôt applicatif.

## 5. Sondes de santé et Actuator

### Pourquoi Actuator

Kubernetes a besoin de savoir deux choses, qui ne sont pas la même :

- **Le processus est-il vivant ?** (_liveness_) Si non, le kubelet tue le
  conteneur et le relance.
- **Peut-on lui envoyer du trafic ?** (_readiness_) Si non, le pod est retiré du
  Service, sans être tué.

Interroger `/` sur le back ne répondrait ni à l'une ni à l'autre : une JVM peut
accepter une connexion TCP bien avant que le contexte Spring soit chargé, et
répondre 404 sur `/` aussi bien quand tout va bien que quand la couche de
persistance est tombée.

`spring-boot-starter-actuator` fournit la vraie réponse. Avec
`management.endpoint.health.probes.enabled=true`, il expose deux ressources
distinctes, alimentées par l'état interne du contexte Spring :

| URL                          | Répond à                                 | Utilisée par                    |
| ---------------------------- | ---------------------------------------- | ------------------------------- |
| `/actuator/health/liveness`  | le contexte applicatif est-il vivant ?   | `startupProbe`, `livenessProbe` |
| `/actuator/health/readiness` | l'application accepte-t-elle du trafic ? | `readinessProbe`                |

### L'exposition est réduite au minimum

Actuator est aussi une surface d'attaque : `/actuator/env` livre toutes les
variables d'environnement, `/actuator/heapdump` un instantané de la mémoire.
`back/src/main/resources/application.properties` restreint donc explicitement :

```properties
management.endpoints.web.exposure.include=health
management.endpoint.health.probes.enabled=true
management.endpoint.health.show-details=never
```

`show-details=never` mérite un mot : sans lui, `/actuator/health` détaille l'état
de chaque composant (base de données, espace disque). Comme l'endpoint est
joignable sans authentification, autant qu'il réponde `UP` ou `DOWN` et rien de
plus.

Vérifié en exécutant le jar construit :

| Requête                      | Réponse                                                   |
| ---------------------------- | --------------------------------------------------------- |
| `/actuator/health`           | `200` `{"status":"UP","groups":["liveness","readiness"]}` |
| `/actuator/health/liveness`  | `200` `{"status":"UP"}`                                   |
| `/actuator/health/readiness` | `200` `{"status":"UP"}`                                   |
| `/actuator/env`              | `404`                                                     |
| `/actuator/beans`            | `404`                                                     |
| `/actuator/configprops`      | `404`                                                     |

### Un `startupProbe` plutôt qu'un `initialDelaySeconds` long

C'est le réglage le moins évident. Une JVM Spring Boot met plusieurs dizaines de
secondes à démarrer, et ce délai dépend de la charge du nœud. Si on ne dit rien,
la `livenessProbe` commence à interroger un processus qui n'a pas fini de
démarrer, échoue trois fois, et le kubelet tue le conteneur — qui redémarre, et
recommence. Un `CrashLoopBackOff` sans aucun bug applicatif.

Le réflexe est de mettre un `initialDelaySeconds: 90` sur la liveness. Ça marche,
mais ça coûte cher : ce délai s'applique **une seule fois**, alors que la
tolérance qu'il achète serait utile au démarrage uniquement. Pire, pour couvrir
le pire cas de démarrage il faut le surdimensionner, et pendant toute la vie du
pod on aura choisi de détecter les blocages plus tard qu'on ne le pourrait.

Le `startupProbe` sépare proprement les deux régimes :

| Sonde       | Chemin                       | Cadence | Seuil | Budget    |
| ----------- | ---------------------------- | ------- | ----- | --------- |
| `startup`   | `/actuator/health/liveness`  | 5 s     | 30    | **150 s** |
| `liveness`  | `/actuator/health/liveness`  | 10 s    | 3     | 30 s      |
| `readiness` | `/actuator/health/readiness` | 5 s     | 3     | 15 s      |

Tant que le `startupProbe` n'a pas réussi une fois, liveness et readiness sont
**suspendues** : le démarrage dispose de 150 s sans risque d'être interrompu. Dès
qu'il réussit, il ne s'exécute plus jamais et les deux autres prennent le relais
avec des délais courts, donc réactifs. On obtient de la patience au démarrage
_et_ de la réactivité ensuite, ce qu'un `initialDelaySeconds` ne permet pas.

Le front n'a pas ce problème : Caddy démarre en quelques dizaines de
millisecondes. Son `startupProbe` est calibré à 15 × 2 s. Caddy n'ayant pas
d'endpoint de santé — son API d'admin écoute sur `localhost:2019` et n'est pas
joignable par le kubelet — les trois sondes interrogent `/`, qui renvoie
`index.html`.

## 6. Le déploiement : deux commandes, dans cet ordre

Les jobs `deploy-staging` et `deploy-production` enchaînent :

```yaml
- kubectl apply -k "$K8S_OVERLAYS_DIR/staging" -n "$STAGING_NAMESPACE"
- bash scripts/deploy/deploy.sh -n "$STAGING_NAMESPACE" -d "$APP_BACK_NAME" ...
```

**1. `kubectl apply -k`** crée ou met à jour la ConfigMap, les Services,
l'Ingress et les Deployments. C'est cette étape qui rend le déploiement
idempotent : sur un cluster vierge elle crée tout, sur un cluster déjà en service
elle ne modifie que ce qui a changé.

**2. `deploy.sh`** pose l'image réellement construite par ce pipeline, attend la
fin du rollout et **revient automatiquement en arrière** si elle n'aboutit pas
dans `$DEPLOY_TIMEOUT`. C'est le garde-fou, et il est inchangé — ses tests
existants (`scripts/tests/run_tests.sh`) continuent de passer.

### Le comportement à connaître sur un cluster vierge

Les manifestes portent une image _placeholder_ (`microcrm/back:PLACEHOLDER`),
puisque le chemin réel dépend de `$CI_REGISTRY_IMAGE` (§4). Sur un cluster
vierge, entre les étapes 1 et 2, Kubernetes tente donc de tirer une image qui
n'existe pas et le premier pod passe quelques secondes en **`ImagePullBackOff`**.
L'étape 2 remplace ensuite l'image par la vraie, un nouveau ReplicaSet est créé,
et c'est celui-là que `rollout status` observe.

Le résultat final est correct, mais il faut le savoir pour ne pas s'alarmer en
regardant `kubectl get pods` entre les deux commandes. Sur un cluster déjà
déployé, le cas ne se présente pas : `apply` ne change pas l'image posée par le
déploiement précédent.

Une variante plus propre existe et pourra être adoptée plus tard : rendre les
manifestes puis substituer l'image avant d'appliquer, ce qui supprime la fenêtre
transitoire —

```shell
kubectl kustomize k8s/overlays/staging \
  | sed "s|microcrm/back:PLACEHOLDER|$CI_REGISTRY_IMAGE/$APP_BACK_NAME:$CI_COMMIT_SHORT_SHA|" \
  | kubectl apply -n "$STAGING_NAMESPACE" -f -
```

Je ne l'ai pas retenue pour cette première version : elle réintroduit une
substitution textuelle sur du YAML rendu, c'est-à-dire exactement le mécanisme de
template que le choix de Kustomize cherchait à éviter (§2). L'arbitrage mérite
d'être revu si la fenêtre d'`ImagePullBackOff` gêne réellement.

## 7. Ce qui varie entre les environnements

| Ce qui change                   | staging                            | production                    |
| ------------------------------- | ---------------------------------- | ----------------------------- |
| `replicas` front                | 1                                  | 2                             |
| `replicas` back                 | 1                                  | **1** (contrainte, §8.1)      |
| Hôte du front                   | `microcrm.staging.example.com`     | `microcrm.example.com`        |
| Hôte de l'API                   | `api.microcrm.staging.example.com` | `api.microcrm.example.com`    |
| `MICROCRM_CORS_ALLOWED_ORIGINS` | l'hôte du front de staging         | l'hôte du front de production |
| `FRONT_API_BASE_URL`            | l'hôte d'API de staging            | l'hôte d'API de production    |
| Ressources du back              | 200 m / 512 Mi → 1 CPU / 768 Mi    | 500 m / 768 Mi → 2 CPU / 1 Gi |
| Label `instance`                | `microcrm-staging`                 | `microcrm-production`         |

Les noms de domaine utilisent `example.com`, réservé aux exemples par la
RFC 2606 : ils sont à remplacer par les vrais le jour où un cluster existera.

### Pourquoi la base porte des hôtes en `.invalid`

`k8s/base/ingress.yaml` déclare `microcrm.invalid` et `api.microcrm.invalid`,
un TLD dont la RFC 2606 garantit qu'il ne résout jamais. C'est délibéré.

Si la base portait les hôtes d'un environnement réel — la production, par
exemple — le patch de cet environnement n'aurait plus rien à changer : il
deviendrait un no-op silencieux. Deux conséquences, toutes deux mauvaises :
modifier la base changerait la production sans qu'aucun overlay ne le laisse
voir, et supprimer le patch de production ne changerait rien, donc personne ne
s'apercevrait de sa disparition.

Avec un hôte non résolvable dans la base, **chaque overlay est obligé de
surcharger**, et un patch oublié se signale au lieu de router vers le mauvais
environnement. `validate_k8s.sh` en fait une assertion : aucun hôte en
`.invalid` ne doit subsister dans le rendu d'un overlay.

### Pas de `namePrefix`, et c'est un piège évité

Le réflexe Kustomize serait d'ajouter `namePrefix: staging-` pour distinguer les
ressources. **Ça casserait le déploiement** : les Deployments s'appelleraient
`staging-back` et `staging-front`, alors que `deploy.sh` cible
`deployment/back`. L'échec serait tardif (au premier déploiement) et le message
peu parlant (« Deployment 'back' introuvable »).

L'isolation entre environnements est déjà assurée par le namespace, qui les rend
étanches. Un préfixe n'ajouterait rien. Le job `lint-k8s` monte la garde sur ce
point précis (§9).

### Deux hôtes plutôt qu'un préfixe `/api`

Le front est une application Angular : c'est le **navigateur de l'utilisateur**
qui appelle l'API, pas le pod front. Le back doit donc être joignable depuis
l'extérieur du cluster ; le Service ClusterIP ne suffit pas.

Router l'API sur `/api` du même hôte aurait supposé de réécrire le chemin avant
de le transmettre, Spring Data REST exposant ses collections à la racine
(`/persons`, `/organizations`). Cette réécriture passe par des annotations propres
à chaque contrôleur d'Ingress — nginx, Traefik et HAProxy ont chacune la leur —
ce qui aurait rendu le manifeste non portable. Un hôte dédié évite la réécriture
et reste du Kubernetes standard.

Corollaire : front et API sont sur des **origines différentes**, donc le CORS
n'est pas décoratif. `MICROCRM_CORS_ALLOWED_ORIGINS` doit contenir l'hôte du
front de l'environnement, schéma compris, sinon le navigateur bloquera toutes les
requêtes. C'est fait dans chaque overlay.

## 8. Les limites assumées

Quatre, et aucune n'est un oubli.

### 8.1 Pas de persistance — et le back plafonné à 1 replica

HSQLDB tourne **en mémoire, dans le processus Java** (`runtimeOnly
'org.hsqldb:hsqldb'`, sans URL de fichier), et les données sont recréées au
démarrage par `InitialDataFixture`. Deux conséquences :

- **Les données disparaissent à chaque redémarrage de pod.** Un rollout, une
  éviction, un `OOMKill` : on repart du jeu de démonstration. C'est acceptable
  pour un projet pédagogique, pas pour un vrai CRM.
- **Le back ne peut pas monter en replicas.** C'est le piège le plus sérieux du
  lot : à deux pods, chacun aurait _sa_ base. Une écriture sur l'un serait
  invisible depuis l'autre, et le Service répartissant les requêtes, une lecture
  sur deux ne verrait pas ce qui vient d'être écrit. Aucune erreur ne serait
  levée — juste une application qui « perd » des données au hasard.

C'est pour cette raison qu'il n'y a **pas de PersistentVolumeClaim** : un volume
ne servirait à rien tant que la base vit dans le tas de la JVM. La vraie sortie
est d'externaliser la base (PostgreSQL), ce qui lèverait les deux limites d'un
coup. En attendant, le plafond à 1 replica est documenté dans
`back-deployment.yaml` et dans les deux overlays, à l'endroit où quelqu'un serait
tenté de changer le chiffre.

### 8.2 La configuration du front est chargée par une requête supplémentaire

_Cette section décrivait jusqu'ici une limite bien plus lourde — `FRONT_API_BASE_URL`
était inerte, et le front déployé appelait `localhost:8080` depuis le poste de
l'utilisateur. Le lot P1 de [VARIABILISATION.md](VARIABILISATION.md) §5 étant
traité, la clé est réellement consommée. Voir §13._

Ce qu'il reste est mineur mais réel : l'application émet une requête
`GET /config.json` **avant** de démarrer. Deux conséquences :

- le premier rendu est retardé du temps de cet aller-retour — négligeable, le
  fichier est servi par Caddy depuis sa mémoire, sans accès disque ;
- si Caddy répond mais que la configuration est illisible, l'application ne
  démarre pas et l'erreur reste dans la console du navigateur. C'est un choix
  délibéré : un repli silencieux sur `localhost:8080` reproduirait exactement la
  panne que ce mécanisme supprime, en la rendant invisible. Le détail des cas est
  dans `front/src/app/config.ts`.

### 8.3 Une modification de la ConfigMap ne redémarre pas les pods

`configmap.yaml` est une ressource ordinaire, pas un `configMapGenerator`. Un
générateur aurait ajouté un suffixe de hachage au nom, ce qui aurait fait changer
le Deployment à chaque modification de la configuration, donc déclenché un
rollout automatique.

J'ai préféré la ressource simple, plus lisible en revue et plus facile à
retrouver dans le cluster (`kubectl get configmap microcrm-config`). Le prix est
qu'après avoir changé une origine CORS il faut relancer les pods à la main :

```shell
kubectl -n "$NAMESPACE" rollout restart deployment/back
```

À basculer sur `configMapGenerator` si l'oubli se produit en pratique.

### 8.4 `lint-k8s` ne valide pas les manifestes contre le schéma de l'API

Le job construit les overlays mais ne vérifie pas que les champs existent
réellement dans l'API Kubernetes. `kubectl apply --dry-run=client` en serait
capable, mais — contrairement à ce que son nom laisse croire — **il interroge le
serveur**, pour télécharger l'OpenAPI, et même avec `--validate=false` pour
résoudre les types :

```
error: error validating "k8s/overlays/staging": failed to download openapi: ...
unable to recognize "k8s/overlays/staging": ... connection refused
```

Or `lint-k8s` tourne sur les branches de feature, où `KUBE_CONFIG` — protégée —
n'est pas disponible, et l'exigence était justement qu'il n'ait pas besoin de
cluster. Une validation de schéma hors ligne demanderait `kubeconform`, à ajouter
au pipeline comme une image d'outillage figée de plus. C'est le prochain
raffinement naturel de ce job.

## 9. Valider en local

Aucune de ces commandes n'a besoin d'un cluster.

```shell
# Construire un overlay et lire ce qui sera réellement envoyé
kubectl kustomize k8s/overlays/staging
kubectl kustomize k8s/overlays/production

# Comparer les deux environnements — le diff doit se limiter au tableau du §7
diff <(kubectl kustomize k8s/overlays/staging) \
     <(kubectl kustomize k8s/overlays/production)

# Rejouer exactement les assertions de la CI
scripts/tests/validate_k8s.sh --autotest
```

Le job **`lint-k8s`** (stage `lint`, image `$KUBECTL_IMAGE`) exécute
`scripts/tests/validate_k8s.sh --autotest` à chaque commit, sur les mêmes règles
que les autres jobs de lint. Le script construit les deux overlays puis assère
sur le rendu ([SCRIPTS.md](SCRIPTS.md)) :

| Ce qui est vérifié                                        | Ce que ça attrape                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------------- |
| Deployments nommés `$APP_BACK_NAME` / `$APP_FRONT_NAME`   | un `namePrefix:` ajouté par réflexe                               |
| conteneurs portant **le même nom**                        | un renommage de conteneur dans la base                            |
| toute ConfigMap référencée existe dans le rendu           | une référence morte, qui bloque le pod sans faire échouer `apply` |
| sondes visant un port déclaré par le conteneur            | un `port:` renommé d'un côté seulement                            |
| `runAsNonRoot` / `allowPrivilegeEscalation` par conteneur | une régression du socle de sécurité                               |
| aucune image en `latest` ni sans tag                      | un déploiement non reproductible                                  |
| valeurs distinctes entre staging et production            | un patch d'overlay qui ne mord pas                                |

Les deux premières lignes sont le **contrat avec `deploy.sh`**, qui exécute
`kubectl set image deployment/back back=…`. Les deux moitiés comptent : renommer
le Deployment donne « Deployment 'back' introuvable », renommer le conteneur
donne « unable to find container named "back" ». Les deux échouent tard, au
déploiement, avec un message qui ne désigne pas la cause.

`--autotest` rejoue ensuite toutes ces assertions sur des rendus volontairement
abîmés et vérifie qu'elles **échouent** bien — une assertion qui ne se déclenche
jamais ne prouve rien.

## 10. Déployer sur un cluster vierge

Prérequis : un cluster, les variables `KUBE_CONFIG`, `STAGING_NAMESPACE` et
`PROD_NAMESPACE` créées dans GitLab ([VARIABILISATION.md](VARIABILISATION.md) §7),
et un contrôleur d'Ingress installé.

1. **Créer le namespace** — il n'est pas dans les manifestes (§4) :

   ```shell
   kubectl create namespace "$STAGING_NAMESPACE"
   ```

2. **Rien à faire pour l'accès au registry si vous déployez par la CI.** Les
   jobs `deploy-staging` et `deploy-production` créent le Secret eux-mêmes,
   avant l'`apply` (§12). Hors CI, il faut le créer à la main :

   ```shell
   kubectl -n "$NAMESPACE" create secret docker-registry gitlab-registry \
     --docker-server=<registry> --docker-username=<user> --docker-password=<token>
   ```

   Le nom `gitlab-registry` n'est pas libre : c'est celui que référencent les
   deux Deployments en `imagePullSecrets`, et celui que porte
   `$REGISTRY_SECRET_NAME` dans le pipeline.

3. **Ajuster les hôtes** dans les `ingress-patch.yaml` des deux overlays, et les
   origines CORS correspondantes dans les `configmap-patch.yaml`.

4. **Lancer le job `deploy-staging`** depuis l'interface GitLab (il est en
   `manual`). Il applique les manifestes puis pose l'image du commit.

5. **Vérifier** :

   ```shell
   kubectl -n "$STAGING_NAMESPACE" get pods,svc,ingress
   kubectl -n "$STAGING_NAMESPACE" rollout status deployment/back
   ```

## 11. Sécurité des conteneurs

Les deux Deployments appliquent le même socle : `runAsNonRoot`,
`allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`,
`readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`, et
`automountServiceAccountToken: false` — rien dans l'application n'appelle l'API
Kubernetes, un jeton monté dans le pod ne serait qu'une surface d'attaque.

Trois points ont demandé une vérification plutôt qu'une supposition.

**L'UID du back.** `back/Dockerfile` crée son utilisateur avec `adduser -D -H
app`, sans UID explicite. Les manifestes doivent pourtant en déclarer un
numérique : `runAsNonRoot` seul laisse le kubelet vérifier trop tard. La commande
a été exécutée dans `alpine:3.19` pour lever le doute — `adduser` attribue le
premier UID libre à partir de 1000, donc `app` vaut **1000:1000**. C'est cette
valeur qui est figée dans `back-deployment.yaml`. Elle reste couplée au
Dockerfile : y ajouter un utilisateur avant `app` la ferait glisser. Un `USER
1000` numérique dans le Dockerfile supprimerait ce couplage — amélioration
possible, non faite ici pour ne pas modifier l'image dans ce lot.

**Le `/tmp` du back.** `readOnlyRootFilesystem: true` empêche la JVM d'écrire, or
elle en a besoin : `hsperfdata` d'une part, et surtout le répertoire de travail
que le Tomcat embarqué de Spring Boot crée au démarrage sous `java.io.tmpdir`.
Sans volume, l'application ne démarre pas. Un `emptyDir` est donc monté sur
`/tmp`.

**Le cas Caddy, qui est le plus surprenant.** L'image officielle tourne en root,
et on pouvait s'attendre à ce que `runAsNonRoot` l'empêche d'écouter sur le port
80 — un port privilégié. Le vrai comportement est différent, et pire :

```
$ docker run --rm --user 1000:1000 --cap-drop ALL caddy:2-alpine caddy run ...
exec /usr/bin/caddy: operation not permitted
```

Le conteneur ne démarre pas **du tout**. La cause n'est pas le port mais le
binaire : `/usr/bin/caddy` porte la _capability de fichier_
`cap_net_bind_service=ep`. Quand cette capability ne figure pas dans l'ensemble
limitant du conteneur, le noyau refuse l'`exec` lui-même, avant qu'une seule
ligne de Caddy ne s'exécute. Vérifié : le comportement est identique **en root
comme en non-root, et sur un port haut comme sur le port 80**.

La conséquence est contre-intuitive et vaut d'être notée : **passer le Caddyfile
en `:8080` ne résoudrait rien.** La seule solution, à image inchangée, est de
rendre la capability :

```yaml
capabilities:
  drop: [ALL]
  add: [NET_BIND_SERVICE]
```

C'est ce que fait `front-deployment.yaml`, et le port 80 est conservé. Testé en
local : Caddy démarre et sert `index.html` en `200` sous `--user 1000:1000
--cap-drop ALL --cap-add NET_BIND_SERVICE --read-only`. Deux `emptyDir` sont
montés sur `/config` et `/data`, où Caddy écrit son autosave de configuration et
son stockage TLS ; sans eux il fonctionne quand même, mais journalise deux
erreurs à chaque démarrage.

L'alternative — reconstruire une image Caddy sans cette capability de fichier et
écouter sur un port haut — supprimerait le besoin de `NET_BIND_SERVICE`. Elle
demande de toucher à `front/Dockerfile` et au `Caddyfile`, ce qui dépasse le
périmètre de ce lot.

## 12. L'accès au registry privé

Le registry GitLab du projet est privé. Sans identifiants, Kubernetes ne peut
tirer aucune des deux images et **tous les pods restent en `ImagePullBackOff`** —
c'était, avant ce lot, le point le plus susceptible de bloquer un premier
déploiement réel.

### Pourquoi le Secret ne peut pas être versionné

Un `Secret` Kubernetes n'est pas chiffré : son champ `data` est du base64, un
encodage, pas une protection. Commiter le Secret reviendrait à publier le mot de
passe du registry, et l'historique Git le conserverait même après correction.
C'est le premier critère de [VARIABILISATION.md](VARIABILISATION.md) §1.

Le Secret est donc la troisième valeur — après le namespace et le chemin du
registry (§4) — que les manifestes référencent sans la contenir.

### Ce que fait la CI

Les jobs `deploy-staging` et `deploy-production` le créent avant l'`apply`,
depuis les variables que GitLab fournit automatiquement :

```shell
kubectl create secret docker-registry "$REGISTRY_SECRET_NAME" \
  --docker-server="$CI_REGISTRY" \
  --docker-username="$CI_REGISTRY_USER" \
  --docker-password="$CI_REGISTRY_PASSWORD" \
  -n "$NAMESPACE" --dry-run=client -o yaml \
  | kubectl apply -n "$NAMESPACE" -f -
```

Trois points méritent une explication.

**Pourquoi ce détour plutôt qu'un simple `create`.** `kubectl create secret`
échoue avec `already exists` dès le deuxième déploiement. La forme
`create --dry-run=client -o yaml | apply -f -` est idempotente : elle crée le
Secret s'il manque, et le met à jour si le mot de passe a changé. C'est le motif
standard pour rendre déclarative une commande qui ne l'est pas.

**`--dry-run=client` fonctionne ici sans serveur d'API**, contrairement à ce que
§8.4 dit de `kubectl apply --dry-run=client`. Ce n'est pas une contradiction :
`create secret` est un _générateur_, il fabrique un objet localement sans avoir à
résoudre son type auprès du cluster. Vérifié hors cluster :

```
$ kubectl create secret docker-registry test --docker-server=... --dry-run=client -o yaml
apiVersion: v1
data:
  .dockerconfigjson: eyJhdXRocyI6...
kind: Secret
```

**Le mot de passe ne doit jamais atteindre le log.** C'est le point le plus
sensible, et il est contre-intuitif : la sortie de `-o yaml` contient le mot de
passe encodé en base64, or **le masquage GitLab travaille sur la valeur
littérale** et ne reconnaît pas cette forme encodée. Décodée, la sortie ci-dessus
donne :

```json
{ "auths": { "registry...": { "username": "u", "password": "p", "auth": "dTpw" } } }
```

Le flux doit donc aller directement dans le tube, sans jamais transiter par le
log du job : pas de `tee`, pas de `cat`, et surtout pas de
`kubectl get secret … -o yaml` ajouté « pour vérifier ». Un commentaire le
rappelle dans `.gitlab-ci.yml`, à l'endroit exact où la tentation se présente.

### `imagePullSecrets` dans les pods, pas sur le ServiceAccount

Les deux façons de rattacher le Secret fonctionnent. J'ai retenu la déclaration
dans le `podSpec` de chaque Deployment.

| Approche                                 | Ce qu'elle implique                                                                      |
| ---------------------------------------- | ---------------------------------------------------------------------------------------- |
| **`imagePullSecrets` dans le podSpec**   | déclaratif, versionné, visible en revue, limité à nos pods                               |
| Rattachement au ServiceAccount `default` | impératif (`kubectl patch`), hors Kustomize, s'applique à **tous** les pods du namespace |

L'argument décisif est de propriété : le ServiceAccount `default` est créé par
Kubernetes dans chaque namespace, il ne nous appartient pas. Le modifier
étendrait l'accès au registry à des pods que nous n'avons pas déployés, ne
laisserait aucune trace dans le dépôt, et ne serait pas défait en supprimant
l'application. Une ressource partagée qu'on modifie sans la posséder est
exactement le genre d'effet de bord qu'on ne retrouve pas six mois plus tard.

### Le nom, et pourquoi il est vérifié

Le nom vit à deux endroits : `$REGISTRY_SECRET_NAME` dans le pipeline (ce que la
CI crée) et `imagePullSecrets` dans les deux Deployments (ce que les pods
cherchent). S'ils divergent, le Secret existe, `kubectl apply` réussit, et les
pods restent malgré tout en `ImagePullBackOff` — une panne silencieuse de plus.

`scripts/tests/validate_k8s.sh` vérifie donc que chaque Deployment du rendu
référence bien `$REGISTRY_SECRET_NAME`, et son mode `--autotest` prouve que
l'assertion se déclenche : sur un rendu dont on retire le `imagePullSecrets`, ou
dont on remplace le nom, elle échoue.

## 13. La configuration d'exécution du front

Ce lot clôt le P1 de [VARIABILISATION.md](VARIABILISATION.md) §5.

### Le problème

`front/Dockerfile` lance `ng build` **pendant** la construction de l'image.
Toute constante du code y est donc figée : `API_BASE_URL = "http://localhost:8080"`
partait dans le bundle JavaScript. L'image de production appelait la machine de
l'utilisateur, et la seule échappatoire aurait été de construire une image par
environnement — c'est-à-dire de ne plus déployer l'artefact qu'on a testé.

### La solution retenue

Caddy fabrique un `/config.json` **au démarrage du conteneur**, et le bundle le
lit avant de démarrer l'application.

```caddyfile
handle /config.json {
	header Content-Type application/json
	respond `{"apiBaseUrl":"{$FRONT_API_BASE_URL:http://localhost:8080}"}`
}
```

La syntaxe `{$VARIABLE:défaut}` est résolue par Caddy au chargement de sa
configuration. **Une seule image sert donc tous les environnements** ; seule la
variable du conteneur change, alimentée par la ConfigMap
(`k8s/base/front-deployment.yaml`) ou par `docker-compose.yml` en local.

Le choix entre les deux mises en œuvre envisagées s'est fait sur le coût :

| Option                                     | Pourquoi pas / pourquoi                                                       |
| ------------------------------------------ | ----------------------------------------------------------------------------- |
| Script d'entrée qui écrit un `config.json` | ajoute un point d'entrée, donc un fichier à tester et à maintenir             |
| **`respond` de Caddy**                     | **aucun code supplémentaire — le serveur qui sert déjà le front s'en charge** |

Un piège a demandé une vérification : les directives d'un Caddyfile sont
réordonnées selon un ordre standard où `try_files` passe **avant** `handle`.
Avec un `try_files` global, `/config.json` était réécrit en `/index.html` et le
front recevait du HTML à la place de sa configuration. D'où les deux blocs
`handle` mutuellement exclusifs.

### Le défaut reste fonctionnel

`front/src/app/config.ts` conserve `http://localhost:8080` comme valeur de repli.
C'est volontaire, et c'est le motif de `tests/k6/lib/config.js` cité en §3 de
VARIABILISATION.md : défaut utilisable, surcharge par environnement, erreur
explicite si la valeur est illisible.

Le repli distingue deux situations, et la distinction est le cœur du dispositif :

| Situation                                 | Comportement                             | Pourquoi                              |
| ----------------------------------------- | ---------------------------------------- | ------------------------------------- |
| `config.json` absent (404, ou `ng serve`) | défaut + trace en console                | c'est le développement, pas une panne |
| `config.json` servi mais JSON invalide    | **erreur, l'application ne démarre pas** | défaut de déploiement                 |
| `apiBaseUrl` absente, vide ou non absolue | **erreur, l'application ne démarre pas** | défaut de déploiement                 |

Retomber silencieusement sur `localhost:8080` dans les deux derniers cas
reproduirait précisément la panne que ce lot supprime, en la rendant invisible.

Le contrôle du type de contenu mérite d'être signalé : le serveur de
développement Angular renvoie `index.html` en **HTTP 200** pour toute route
inconnue. Sans vérifier que la réponse s'annonce en `application/json`, on
tenterait d'analyser du HTML comme du JSON et on lèverait une erreur à tort en
plein `ng serve`.

### Ce que le port du Caddyfile n'apporte pas

`front/Caddyfile` accepte désormais `{$SITE_PORT:80}`. C'est un réglage de
souplesse, **pas une amélioration de sécurité** : comme établi au §11, c'est la
capability de fichier `cap_net_bind_service=ep` portée par le binaire Caddy — et
non le numéro de port — qui impose de conserver `NET_BIND_SERVICE` dans le
conteneur. Écouter sur un port haut ne dispenserait de rien.
