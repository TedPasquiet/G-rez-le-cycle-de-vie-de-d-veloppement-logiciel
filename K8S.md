# Déploiement Kubernetes

Description de l'infrastructure de déploiement de MicroCRM : les manifestes du
dossier `k8s/`, la façon dont la CI les applique, les preuves de leur
fonctionnement sur un cluster réel, et leurs limites.

**État.** Les manifestes sont appliqués par les jobs `deploy-staging` et
`deploy-production` sur un cluster minikube (Kubernetes v1.35.1), dans les
namespaces `microcrm-staging` et `microcrm-production`, avec des images tirées
du registry GitLab. La production tourne `back:1.0.1` et `front:1.0.1` depuis
le 2026-10-05. Le rollout, les sondes, l'Ingress, le retour arrière automatique
et le job `rollback-production` sont vérifiés sur cluster ; les preuves sont
rassemblées au **§14**.

## 1. Le problème que ça résout

`scripts/deploy/deploy.sh` sait mettre à jour un déploiement, mais pas le
**créer**. Le script commence par :

```bash
kubectl -n "$namespace" get deployment "$deployment" >/dev/null 2>&1 \
  || die "Deployment '$deployment' introuvable dans le namespace '$namespace'"
```

Sur un cluster vierge, ce test échoue toujours. Sans manifestes, il faudrait
créer les ressources à la main, c'est-à-dire avoir un environnement dont
personne ne peut dire comment il a été construit, ni le reconstruire à
l'identique.

C'est ce que l'**infrastructure as code** évite : l'état voulu du cluster est
décrit dans des fichiers versionnés, relus en revue, et appliqués par la CI. Un
environnement perdu se recrée avec une commande.

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

D'abord, **Kustomize est déjà là**. `alpine/kubectl:1.34.2`, l'image figée dans
le pipeline pour le stage `deploy`, sait faire `kubectl apply -k` sans rien
installer. Helm aurait ajouté un outil à épingler, à mettre à jour et à
surveiller, pour un dépôt qui n'a que deux services.

Ensuite, **Helm résout un problème que ce projet n'a pas**. Sa force est de
_distribuer_ un composant paramétrable à des gens qui ne le connaissent pas :
d'où les `values.yaml`, les conditions, les boucles. Ici les manifestes ne
sortent pas du dépôt et ne servent qu'à une application. Le prix des templates —
du YAML qu'on ne peut plus relire directement, ni valider sans le rendre —
n'achèterait rien.

Un troisième argument compte en revue : avec Kustomize, **un overlay est un
manifeste Kubernetes normal**. Une différence entre staging et production se lit
comme du Kubernetes, pas comme une expression de template.

Un chart Helm équivalent existe aussi dans `helm/microcrm/`, parce que le brief
le demande ; son rendu est contrôlé identique à celui de Kustomize, mais c'est
Kustomize que la CI applique ([HELM.md](HELM.md)).

## 3. L'arborescence

```
k8s/
  base/                     # la forme de l'application, commune à tous
    kustomization.yaml
    configmap.yaml          # CORS, URL de l'API, profil Spring, agent OpenTelemetry
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

| Valeur absente            | D'où elle vient                                           | Pourquoi pas dans le dépôt                           |
| ------------------------- | --------------------------------------------------------- | ---------------------------------------------------- |
| Le **namespace**          | `$STAGING_NAMESPACE` / `$PROD_NAMESPACE`                  | déjà externalisées, et `PROD_NAMESPACE` est protégée |
| Le **chemin du registry** | `$CI_REGISTRY_IMAGE` + le tag (SHA court, ou version tag) | dépend du projet GitLab, et le tag dépend du commit  |

C'est la suite directe de la démarche de [VARIABILISATION.md](VARIABILISATION.md).
Écrire `namespace: microcrm-prod` dans `overlays/production/kustomization.yaml`
remettrait dans le dépôt une coordonnée d'infrastructure, et créerait une
seconde source de vérité, qui finit toujours par diverger de la première.

La règle est donc : **Kustomize décrit la forme, la CI fournit les coordonnées.**

- Le namespace arrive par la ligne de commande :
  `kubectl apply -k … -n "$STAGING_NAMESPACE"`.
- L'image arrive par l'overlay éphémère composé par le job (§6).

Le namespace doit donc **exister avant** le premier déploiement. Il est créé
par Terraform, avec son quota et ses garde-fous ([TERRAFORM.md](TERRAFORM.md)) :
sa création est un acte d'administration du cluster, qui ne relève pas du dépôt
applicatif.

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

`show-details=never` : sans lui, `/actuator/health` détaille l'état de chaque
composant (base de données, espace disque). Comme l'endpoint est joignable sans
authentification, il répond `UP` ou `DOWN` et rien de plus.

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

Une JVM Spring Boot met plusieurs secondes à démarrer, et ce délai dépend de la
charge du nœud. Sans précaution, la `livenessProbe` interroge un processus qui
n'a pas fini de démarrer, échoue trois fois, et le kubelet tue le conteneur —
qui redémarre, et recommence. Un `CrashLoopBackOff` sans aucun bug applicatif.

Un `initialDelaySeconds: 90` sur la liveness éviterait ce piège, mais il coûte
cher : pour couvrir le pire cas de démarrage il faut le surdimensionner, et
pendant toute la vie du pod on détecte les blocages plus tard qu'on ne le
pourrait.

Le `startupProbe` sépare proprement les deux régimes :

| Sonde       | Chemin                       | Cadence | Seuil | Budget    |
| ----------- | ---------------------------- | ------- | ----- | --------- |
| `startup`   | `/actuator/health/liveness`  | 5 s     | 30    | **150 s** |
| `liveness`  | `/actuator/health/liveness`  | 10 s    | 3     | 30 s      |
| `readiness` | `/actuator/health/readiness` | 5 s     | 3     | 15 s      |

Tant que le `startupProbe` n'a pas réussi une fois, liveness et readiness sont
**suspendues** : le démarrage dispose de 150 s sans risque d'être interrompu. Dès
qu'il réussit, il ne s'exécute plus et les deux autres prennent le relais avec
des délais courts, donc réactifs. On obtient de la patience au démarrage _et_ de
la réactivité ensuite, ce qu'un `initialDelaySeconds` ne permet pas. Le
comportement observé sous kubelet est au §14.3.

Le front n'a pas ce problème : Caddy démarre en quelques dizaines de
millisecondes. Son `startupProbe` est calibré à 15 × 2 s. Caddy n'ayant pas
d'endpoint de santé — son API d'admin écoute sur `localhost:2019` et n'est pas
joignable par le kubelet — les trois sondes interrogent `/`, qui renvoie
`index.html`.

## 6. Le déploiement : quatre étapes, dans cet ordre

Les jobs `deploy-staging` et `deploy-production` (`.gitlab/ci/deploy.yml`)
enchaînent, après le garde-fou `exige_namespace` qui fait échouer le job si le
namespace n'est pas défini :

```yaml
- kubectl create secret docker-registry … | kubectl apply -f - # 1
- build_deploy_overlay staging # 2
- kubectl apply -k "$DEPLOY_OVERLAY_DIR" -n "$STAGING_NAMESPACE" # 3
- bash scripts/deploy/deploy.sh -n … -d "$APP_BACK_NAME" … # 4 (back, puis front)
```

**1. Le Secret du registry**, que les deux Deployments référencent en
`imagePullSecrets` (§12). Il vient d'abord parce que sans lui les pods créés à
l'étape 3 ne pourraient pas tirer leurs images.

**2. `build_deploy_overlay`** (`.gitlab/ci/templates.yml`) fabrique un overlay
Kustomize éphémère qui compose l'overlay d'environnement et pose par-dessus le
chemin de registry et le tag d'image (`$DEPLOY_IMAGE_TAG` : le SHA court du
commit, ou le numéro de version sur un tag) :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../k8s/overlays/staging
images:
  - name: microcrm/back # la clé : l'image *placeholder* des manifestes
    newName: registry.example.com/groupe/projet/back
    newTag: abc1234
```

**3. `kubectl apply -k`** envoie cet overlay. L'état désiré reçu par le cluster
porte donc **directement la bonne image** : aucun placeholder ne quitte le
dépôt.

**4. `deploy.sh`** attend la fin du rollout et **revient automatiquement en
arrière** s'il n'aboutit pas dans `$DEPLOY_TIMEOUT`. Son `kubectl set image` est
un **no-op** — l'étape 3 a déjà posé la bonne image — et il ne crée donc aucune
révision supplémentaire (vérifié, §14.10). Il est gardé pour l'attente de
rollout et pour le garde-fou, couverts par les 430 assertions de
`scripts/tests/run_tests.sh`.

### Pourquoi un overlay éphémère, et pas autre chose

Trois voies mènent au même résultat ; c'est la contrainte d'outillage qui
tranche.

| Voie                             | Pourquoi elle n'est pas retenue                                                                                                                              |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `kustomize edit set image`       | `$KUBECTL_IMAGE` (`alpine/kubectl`) ne contient **que** le binaire `kubectl` — pas de `kustomize` autonome. Il faudrait figer une image d'outillage de plus. |
| `sed` sur le YAML rendu          | Réintroduit une substitution textuelle sur du YAML, c'est-à-dire le mécanisme de template que le choix de Kustomize cherche à éviter (§2).                   |
| **Overlay éphémère + `images:`** | Le Kustomize **embarqué dans `kubectl`** suffit. Aucune image d'outillage supplémentaire, et la substitution reste structurée, pas textuelle.                |

Deux points d'implémentation ne sont pas devinables :

- **Le répertoire doit être dans le dépôt, désigné par un chemin relatif.**
  Kustomize refuse un chemin absolu dans `resources` (`new root … cannot be
absolute`), donc un répertoire sous `/tmp` ne convient pas. Il vit en
  `.k8s-deploy-overlay/` (`$DEPLOY_OVERLAY_DIR`) et il est dans `.gitignore`.
- **Le préfixe `microcrm/` est une clé de correspondance.** C'est lui qui relie
  le transformateur `images:` aux manifestes ; s'il changeait d'un côté
  seulement, la substitution ne mordrait plus et le placeholder partirait tel
  quel. Il est donc nommé (`$K8S_PLACEHOLDER_IMAGE_PREFIX`) et un garde-fou de
  `build_deploy_overlay` échoue si le rendu contient encore `PLACEHOLDER`.

Les manifestes de `k8s/base/` gardent leur placeholder : c'est ce qui permet à
`lint-k8s` de les valider sans aucune coordonnée de registry, sur des branches
où les variables protégées ne sont pas disponibles (§4, §8.4).

### Pourquoi l'image doit être posée avant l'`apply`

L'alternative naïve — appliquer les manifestes avec leur placeholder, puis
poser l'image par `kubectl set image` — casse le retour arrière, sans que la
disponibilité le laisse voir :

- `kubectl set image` ne met pas à jour l'annotation
  `kubectl.kubernetes.io/last-applied-configuration`, qui continue de porter
  `PLACEHOLDER`.
- `kubectl apply` réécrit tout champ **présent** dans la configuration désirée ;
  l'annotation ne sert qu'à détecter les champs _supprimés_. Chaque `apply`
  repose donc `PLACEHOLDER`, même sur un déploiement sain.
- Chaque déploiement insère alors **deux** révisions : le placeholder, puis la
  vraie image. La « révision précédente » d'un déploiement sain est toujours le
  placeholder, et `rollback-production`, qui appelle `rollback.sh` sans
  `--to-revision`, viserait une image inexistante.
- `maxUnavailable: 0` masque entièrement le défaut : les anciens pods ne sont
  retirés qu'une fois les nouveaux `Ready`, ce qui n'arrive jamais avec le
  placeholder. Le service reste servi, toutes les requêtes en `200`.

Ce scénario a été reproduit sur cluster le 2026-08-10 (deux révisions par
déploiement, rollback sans argument en échec sur `PLACEHOLDER`). Avec l'overlay
éphémère, l'état désiré et l'annotation portent la même image réelle : un
déploiement insère **une seule** révision, et la révision précédente est la
version précédente réellement déployée (§14.10). Un défaut peut être invisible
en disponibilité et grave en exploitabilité : c'est l'historique des révisions
qu'il faut vérifier, pas seulement le service.

### Conséquences pour l'ordre des étapes

- **Pas de fenêtre d'`ImagePullBackOff`** : l'`apply` crée directement des pods
  avec la bonne image, y compris sur un cluster vierge.
- **Un seul `apply` pose l'image des deux Deployments**, puis `deploy.sh` est
  appelé **deux fois, en série** : le back d'abord, le front ensuite. Si le back
  échoue, `deploy.sh` sort en `3`, le job s'arrête et la seconde commande n'est
  pas exécutée. Le Deployment `front` porte déjà la nouvelle image, mais
  personne n'attend son rollout ni ne le ramène en arrière s'il échoue. _(Déduit
  du mécanisme, non rejoué en provoquant un échec du back.)_
- **`deploy-staging` est manuel et bloquant**, comme `deploy-production` : un
  échec du déploiement en staging fait échouer le pipeline.

## 7. Ce qui varie entre les environnements

| Ce qui change                   | staging                            | production                    |
| ------------------------------- | ---------------------------------- | ----------------------------- |
| `replicas` front                | 1                                  | 2                             |
| `replicas` back                 | 1                                  | **1** (contrainte, §8.1)      |
| Hôte du front                   | `microcrm.staging.example.com`     | `microcrm.example.com`        |
| Hôte de l'API                   | `api.microcrm.staging.example.com` | `api.microcrm.example.com`    |
| `MICROCRM_CORS_ALLOWED_ORIGINS` | l'hôte du front de staging         | l'hôte du front de production |
| `FRONT_API_BASE_URL`            | l'hôte d'API de staging            | l'hôte d'API de production    |
| `OTEL_RESOURCE_ATTRIBUTES`      | `deployment.environment=staging`   | `…=production`                |
| Ressources du back              | 200 m / 512 Mi → 1 CPU / 768 Mi    | 500 m / 768 Mi → 2 CPU / 1 Gi |
| Label `instance`                | `microcrm-staging`                 | `microcrm-production`         |

Les noms de domaine utilisent `example.com`, réservé aux exemples par la
RFC 2606 : ils sont à remplacer par les vrais sur un cluster exposé.

### Pourquoi la base porte des hôtes en `.invalid`

`k8s/base/ingress.yaml` déclare `microcrm.invalid` et `api.microcrm.invalid`,
un TLD dont la RFC 2606 garantit qu'il ne résout jamais. C'est délibéré.

Si la base portait les hôtes d'un environnement réel — la production, par
exemple — le patch de cet environnement n'aurait plus rien à changer : il
deviendrait un no-op silencieux. Modifier la base changerait la production sans
qu'aucun overlay ne le laisse voir, et supprimer le patch de production ne
changerait rien, donc personne ne s'apercevrait de sa disparition.

Avec un hôte non résolvable dans la base, **chaque overlay est obligé de
surcharger**, et un patch oublié se signale au lieu de router vers le mauvais
environnement. `validate_k8s.sh` en fait une assertion : aucun hôte en
`.invalid` ne doit subsister dans le rendu d'un overlay.

### Pas de `namePrefix`

Le réflexe Kustomize serait d'ajouter `namePrefix: staging-` pour distinguer les
ressources. **Ça casserait le déploiement** : les Deployments s'appelleraient
`staging-back` et `staging-front`, alors que `deploy.sh` cible
`deployment/back`. L'échec serait tardif (au premier déploiement) et le message
peu parlant (« Deployment 'back' introuvable »).

L'isolation entre environnements est déjà assurée par le namespace. Un préfixe
n'ajouterait rien. Le job `lint-k8s` monte la garde sur ce point précis (§9).

### Deux hôtes plutôt qu'un préfixe `/api`

Le front est une application Angular : c'est le **navigateur de l'utilisateur**
qui appelle l'API, pas le pod front. Le back doit donc être joignable depuis
l'extérieur du cluster ; le Service ClusterIP ne suffit pas.

Router l'API sur `/api` du même hôte supposerait de réécrire le chemin avant de
le transmettre, Spring Data REST exposant ses collections à la racine
(`/persons`, `/organizations`). Cette réécriture passe par des annotations propres
à chaque contrôleur d'Ingress — nginx, Traefik et HAProxy ont chacun la leur —
ce qui rendrait le manifeste non portable. Un hôte dédié évite la réécriture et
reste du Kubernetes standard.

Corollaire : front et API sont sur des **origines différentes**, donc le CORS
n'est pas décoratif. `MICROCRM_CORS_ALLOWED_ORIGINS` doit contenir l'hôte du
front de l'environnement, schéma compris, sinon le navigateur bloque toutes les
requêtes. C'est fait dans chaque overlay.

### Pas d'`ingressClassName` dans la base

La base ne fixe pas de classe d'Ingress : le contrôleur est une propriété du
cluster cible, donc de l'environnement. Sur minikube, l'addon `ingress` déclare
sa classe `nginx` par défaut et l'API server la renseigne seule (§14.4). Un
cluster sans classe par défaut refuserait l'Ingress : le champ irait alors dans
l'overlay, pas dans la base.

## 8. Les limites assumées

Quatre, et aucune n'est un oubli.

### 8.1 Pas de persistance — et le back plafonné à 1 replica

HSQLDB tourne **en mémoire, dans le processus Java** (`runtimeOnly
'org.hsqldb:hsqldb'`, sans URL de fichier), et les données sont recréées au
démarrage par `InitialDataFixture`. Deux conséquences :

- **Les données disparaissent à chaque redémarrage de pod.** Un rollout, une
  éviction, un `OOMKill` : on repart du jeu de démonstration. C'est acceptable
  pour un projet pédagogique, pas pour un vrai CRM.
- **Le back ne peut pas monter en replicas.** À deux pods, chacun aurait _sa_
  base. Une écriture sur l'un serait invisible depuis l'autre, et le Service
  répartissant les requêtes, une lecture sur deux ne verrait pas ce qui vient
  d'être écrit. Aucune erreur ne serait levée — juste une application qui
  « perd » des données au hasard.
- **La perte du pod back coupe l'API** : 16,1 s d'indisponibilité totale
  mesurées (§14.7). `maxUnavailable: 0` protège les déploiements, pas la perte
  d'un pod.

C'est pour cette raison qu'il n'y a **pas de PersistentVolumeClaim** : un volume
ne servirait à rien tant que la base vit dans le tas de la JVM. La vraie sortie
est d'externaliser la base (PostgreSQL), ce qui lèverait ces limites d'un coup.
Le plafond à 1 replica est documenté dans `back-deployment.yaml` et dans les deux
overlays, à l'endroit où quelqu'un serait tenté de changer le chiffre.

### 8.2 La configuration du front est chargée par une requête supplémentaire

L'application émet une requête `GET /config.json` **avant** de démarrer (§13).
Deux conséquences :

- le premier rendu est retardé du temps de cet aller-retour — négligeable, le
  fichier est servi par Caddy depuis sa mémoire, sans accès disque ;
- si Caddy répond mais que la configuration est illisible, l'application ne
  démarre pas et l'erreur reste dans la console du navigateur. C'est un choix
  délibéré : un repli silencieux sur `localhost:8080` produirait un front qui
  appelle le poste de l'utilisateur, panne invisible. Le détail des cas est dans
  `front/src/app/config.ts`.

### 8.3 Une modification de la ConfigMap ne redémarre pas les pods

`configmap.yaml` est une ressource ordinaire, pas un `configMapGenerator`. Un
générateur ajouterait un suffixe de hachage au nom, ce qui ferait changer le
Deployment à chaque modification de la configuration, donc déclencherait un
rollout automatique.

La ressource simple est plus lisible en revue et plus facile à retrouver dans
le cluster (`kubectl get configmap microcrm-config`). Le prix est qu'après avoir
changé une origine CORS il faut relancer les pods à la main :

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
n'est pas disponible, et il ne doit pas avoir besoin de cluster. Une validation
de schéma hors ligne demanderait `kubeconform`, à ajouter au pipeline comme une
image d'outillage figée de plus. C'est le prochain raffinement naturel de ce
job.

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
`scripts/tests/validate_k8s.sh --autotest` à chaque commit. Le script construit
les deux overlays puis vérifie le rendu ([SCRIPTS.md](SCRIPTS.md)) :

| Ce qui est vérifié                                        | Ce que ça attrape                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------------- |
| Deployments nommés `$APP_BACK_NAME` / `$APP_FRONT_NAME`   | un `namePrefix:` ajouté par réflexe                               |
| conteneurs portant **le même nom**                        | un renommage de conteneur dans la base                            |
| toute ConfigMap référencée existe dans le rendu           | une référence morte, qui bloque le pod sans faire échouer `apply` |
| sondes visant un port déclaré par le conteneur            | un `port:` renommé d'un côté seulement                            |
| `runAsNonRoot` / `allowPrivilegeEscalation` par conteneur | une régression du socle de sécurité                               |
| aucune image en `latest` ni sans tag                      | un déploiement non reproductible                                  |
| valeurs distinctes entre staging et production            | un patch d'overlay qui ne mord pas                                |
| `imagePullSecrets` égal à `$REGISTRY_SECRET_NAME`         | un Secret créé sous un autre nom que celui que cherchent les pods |

Les deux premières lignes sont le **contrat avec `deploy.sh`**, qui exécute
`kubectl set image deployment/back back=…`. Les deux moitiés comptent : renommer
le Deployment donne « Deployment 'back' introuvable », renommer le conteneur
donne « unable to find container named "back" ». Les deux échouent tard, au
déploiement, avec un message qui ne désigne pas la cause.

`--autotest` rejoue ensuite ces assertions sur des rendus volontairement abîmés
et vérifie qu'elles **échouent** bien — une assertion qui ne se déclenche jamais
ne prouve rien. Au 2026-10-06 : 174 tests, 0 en échec.

## 10. Déployer sur un cluster vierge

Prérequis : un cluster et un contrôleur d'Ingress (installés par Ansible,
[ANSIBLE.md](ANSIBLE.md)), l'agent GitLab connecté au cluster, et les variables
`STAGING_NAMESPACE` et `PROD_NAMESPACE` créées dans GitLab
([VARIABILISATION.md](VARIABILISATION.md) §7).

1. **Créer le namespace** — il n'est pas dans les manifestes (§4). Le namespace,
   son `ResourceQuota`, son `LimitRange` et ses `NetworkPolicy` sont décrits
   dans `terraform/environments/<env>/` et créés par `terraform apply`
   ([TERRAFORM.md](TERRAFORM.md) §3 pour le partage des responsabilités, §10
   pour la commande). En dépannage seulement, la commande ci-dessous suffit à
   déployer, mais elle produit un namespace **sans aucun garde-fou de
   consommation** :

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
   `manual`). Il crée le Secret, compose l'overlay éphémère portant l'image du
   commit, l'applique, puis attend le rollout avec `deploy.sh` (§6).

   Hors CI, la même chose à la main — le répertoire éphémère doit être **dans le
   dépôt**, Kustomize refusant un chemin absolu dans `resources` :

   ```shell
   mkdir -p .k8s-deploy-overlay
   cat > .k8s-deploy-overlay/kustomization.yaml <<EOF
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../k8s/overlays/staging
   images:
     - name: microcrm/back
       newName: <registry>/back
       newTag: <tag>
     - name: microcrm/front
       newName: <registry>/front
       newTag: <tag>
   EOF
   kubectl apply -k .k8s-deploy-overlay -n "$NAMESPACE"
   ```

5. **Vérifier** :

   ```shell
   kubectl -n "$STAGING_NAMESPACE" get pods,svc,ingress
   kubectl -n "$STAGING_NAMESPACE" rollout status deployment/back
   kubectl -n "$STAGING_NAMESPACE" rollout history deployment/back
   ```

   L'historique ne doit contenir aucune révision `PLACEHOLDER` (§6).

## 11. Sécurité des conteneurs

Les deux Deployments appliquent le même socle : `runAsNonRoot`,
`allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`,
`readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`, et
`automountServiceAccountToken: false` — rien dans l'application n'appelle l'API
Kubernetes, un jeton monté dans le pod ne serait qu'une surface d'attaque.

Trois points reposent sur une vérification plutôt que sur une supposition.

**L'UID du back.** `back/Dockerfile` crée son utilisateur avec `adduser -D -H
app`, sans UID explicite. Les manifestes doivent pourtant en déclarer un
numérique : `runAsNonRoot` seul laisse le kubelet vérifier trop tard. Exécuté
dans `alpine:3.24`, `adduser` attribue le premier UID libre à partir de 1000,
donc `app` vaut **1000:1000**. C'est cette valeur qui est figée dans
`back-deployment.yaml`. Elle reste couplée au Dockerfile : y ajouter un
utilisateur avant `app` la ferait glisser. Un `adduser -u 1000` explicite, comme
dans `front/Dockerfile`, supprimerait ce couplage.

**Le `/tmp` du back.** `readOnlyRootFilesystem: true` empêche la JVM d'écrire, or
elle en a besoin : `hsperfdata` d'une part, et surtout le répertoire de travail
que le Tomcat embarqué de Spring Boot crée au démarrage sous `java.io.tmpdir`.
Sans volume, l'application ne démarre pas. Un `emptyDir` est donc monté sur
`/tmp`.

**La capability de Caddy.** Le binaire `/usr/bin/caddy` porte la _capability de
fichier_ `cap_net_bind_service=ep`, posée dans `front/Dockerfile` comme le fait
l'image officielle. Quand cette capability ne figure pas dans l'ensemble
limitant du conteneur, le noyau refuse l'`exec` lui-même, avant qu'une seule
ligne de Caddy ne s'exécute :

```
$ docker run --rm --user 1000:1000 --cap-drop ALL <image front> caddy run ...
exec /usr/bin/caddy: operation not permitted
```

Le comportement est identique **en root comme en non-root, et sur un port haut
comme sur le port 80** : passer le Caddyfile en `:8080` ne résoudrait rien. À
image inchangée, la seule solution est de rendre la capability :

```yaml
capabilities:
  drop: [ALL]
  add: [NET_BIND_SERVICE]
```

C'est ce que fait `front-deployment.yaml`, et le port 80 est conservé. Caddy
démarre et sert `index.html` en `200` sous `--user 1000:1000 --cap-drop ALL
--cap-add NET_BIND_SERVICE --read-only`. Trois `emptyDir` sont montés sur
`/config`, `/data` et `/tmp`, où Caddy écrit son autosave de configuration et
son stockage TLS.

L'alternative — ne pas poser la capability de fichier dans l'image et écouter
sur un port haut — supprimerait le besoin de `NET_BIND_SERVICE`. Elle demande de
modifier ensemble `front/Dockerfile`, le `Caddyfile` (`{$SITE_PORT:80}`), les
Services et les sondes.

## 12. L'accès au registry privé

Les images sont tirées du registry GitLab du projet. Sans identifiants valides,
Kubernetes ne peut tirer aucune des deux images et **tous les pods restent en
`ImagePullBackOff`**.

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

**Le mot de passe ne doit jamais atteindre le log.** La sortie de `-o yaml`
contient le mot de passe encodé en base64, or **le masquage GitLab travaille sur
la valeur littérale** et ne reconnaît pas cette forme encodée. Décodée, la
sortie ci-dessus donne :

```json
{ "auths": { "registry...": { "username": "u", "password": "p", "auth": "dTpw" } } }
```

Le flux doit donc aller directement dans le tube, sans jamais transiter par le
log du job : pas de `tee`, pas de `cat`, et surtout pas de
`kubectl get secret … -o yaml` ajouté « pour vérifier ». Un commentaire le
rappelle dans `.gitlab/ci/deploy.yml`, à l'endroit exact où la tentation se
présente.

### `imagePullSecrets` dans les pods, pas sur le ServiceAccount

Les deux façons de rattacher le Secret fonctionnent. La déclaration dans le
`podSpec` de chaque Deployment est retenue.

| Approche                                 | Ce qu'elle implique                                                                      |
| ---------------------------------------- | ---------------------------------------------------------------------------------------- |
| **`imagePullSecrets` dans le podSpec**   | déclaratif, versionné, visible en revue, limité à nos pods                               |
| Rattachement au ServiceAccount `default` | impératif (`kubectl patch`), hors Kustomize, s'applique à **tous** les pods du namespace |

L'argument décisif est de propriété : le ServiceAccount `default` est créé par
Kubernetes dans chaque namespace, il n'appartient pas à l'application. Le
modifier étendrait l'accès au registry à des pods qu'elle n'a pas déployés, ne
laisserait aucune trace dans le dépôt, et ne serait pas défait en supprimant
l'application.

### Le nom, et pourquoi il est vérifié

Le nom vit à deux endroits : `$REGISTRY_SECRET_NAME` dans le pipeline (ce que la
CI crée) et `imagePullSecrets` dans les deux Deployments (ce que les pods
cherchent). S'ils divergent, le Secret existe, `kubectl apply` réussit, et les
pods restent malgré tout en `ImagePullBackOff` — une panne silencieuse.

`scripts/tests/validate_k8s.sh` vérifie donc que chaque Deployment du rendu
référence bien `$REGISTRY_SECRET_NAME`, et son mode `--autotest` prouve que
l'assertion se déclenche : sur un rendu dont on retire le `imagePullSecrets`, ou
dont on remplace le nom, elle échoue.

## 13. La configuration d'exécution du front

Ce mécanisme répond au P1 de [VARIABILISATION.md](VARIABILISATION.md) §5.

### Le problème

`front/Dockerfile` lance `ng build` **pendant** la construction de l'image.
Toute constante du code y est donc figée dans le bundle JavaScript. Une URL
d'API écrite en dur obligerait à construire une image par environnement —
c'est-à-dire à ne plus déployer l'artefact qu'on a testé.

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

Le choix entre les deux mises en œuvre possibles se fait sur le coût :

| Option                                     | Pourquoi pas / pourquoi                                                       |
| ------------------------------------------ | ----------------------------------------------------------------------------- |
| Script d'entrée qui écrit un `config.json` | ajoute un point d'entrée, donc un fichier à tester et à maintenir             |
| **`respond` de Caddy**                     | **aucun code supplémentaire — le serveur qui sert déjà le front s'en charge** |

Les directives d'un Caddyfile sont réordonnées selon un ordre standard où
`try_files` passe **avant** `handle`. Avec un `try_files` global,
`/config.json` serait réécrit en `/index.html` et le front recevrait du HTML à
la place de sa configuration. D'où les deux blocs `handle` mutuellement
exclusifs.

### Le défaut reste fonctionnel

`front/src/app/config.ts` conserve `http://localhost:8080` comme valeur de repli.
C'est le motif de `tests/k6/lib/config.js` cité en §3 de VARIABILISATION.md :
défaut utilisable, surcharge par environnement, erreur explicite si la valeur
est illisible.

Le repli distingue deux situations, et la distinction est le cœur du dispositif :

| Situation                                 | Comportement                             | Pourquoi                              |
| ----------------------------------------- | ---------------------------------------- | ------------------------------------- |
| `config.json` absent (404, ou `ng serve`) | défaut + trace en console                | c'est le développement, pas une panne |
| `config.json` servi mais JSON invalide    | **erreur, l'application ne démarre pas** | défaut de déploiement                 |
| `apiBaseUrl` absente, vide ou non absolue | **erreur, l'application ne démarre pas** | défaut de déploiement                 |

Retomber silencieusement sur `localhost:8080` dans les deux derniers cas
produirait un front déployé qui appelle le poste de l'utilisateur, sans que
rien ne le signale.

Le serveur de développement Angular renvoie `index.html` en **HTTP 200** pour
toute route inconnue. Le code vérifie donc que la réponse s'annonce en
`application/json` ; sans ce contrôle, il tenterait d'analyser du HTML comme du
JSON et lèverait une erreur à tort en plein `ng serve`.

### Ce que le port du Caddyfile n'apporte pas

`front/Caddyfile` accepte `{$SITE_PORT:80}`. C'est un réglage de souplesse,
**pas une amélioration de sécurité** : comme établi au §11, c'est la capability
de fichier portée par le binaire Caddy — et non le numéro de port — qui impose
de conserver `NET_BIND_SERVICE` dans le conteneur.

## 14. Déploiement réel : procédure et preuves

Deux chemins mènent au cluster. **La CI** (`deploy-staging`,
`deploy-production`, `rollback-production`) déploie les images du registry
GitLab par l'agent GitLab ; c'est le chemin normal. **Le poste**, avec
`kubectl` et `minikube image load`, sert à rejouer et à mesurer ce qu'un job ne
montre pas (§14.9).

### 14.1 L'environnement

| Élément    | Valeur                                                                   |
| ---------- | ------------------------------------------------------------------------ |
| Cluster    | minikube v1.38.1, driver `docker`, nœud unique                           |
| Kubernetes | v1.35.1 (client `kubectl` v1.36.2 sur le poste, v1.34.2 dans la CI)      |
| Namespaces | `microcrm-staging`, `microcrm-production` (Terraform)                    |
| Contrôleur | ingress-nginx v1.14.3 (addon `ingress` de minikube)                      |
| Images, CI | registry GitLab, tag SHA court ou numéro de version                      |
| Images, à  | `minikube image load`, tag explicite et immuable (`t2-<sha court>`), pas |
| la main    | `latest`, conformément à l'assertion de `validate_k8s.sh`                |

Sur le poste, les images sont livrées par `minikube image load` plutôt que par
un registry local : un registry minikube sans authentification n'exercerait pas
davantage le chemin `imagePullSecrets`, que la CI exerce déjà, et ajouterait une
configuration TLS à régler.

### 14.2 Les preuves

| Date       | Ce qui a été joué                                                             | Résultat                                                                                                                             |
| ---------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 2026-08-10 | `apply -k` de l'overlay `staging` sur un namespace vierge                     | les six objets créés ; `rollout status` en `0` pour les deux Deployments, back en 10,5 s                                             |
| 2026-08-10 | Démarrage du back sous kubelet, trois mesures                                 | `startupProbe` en échec 1 à 2 fois puis réussi ; Spring prêt en 6,7 à 9,8 s ; `Ready` 10 à 15 s après le démarrage du conteneur      |
| 2026-08-10 | Ingress, quatre requêtes par en-tête `Host:`                                  | front `200` HTML, API `200` HAL, `/persons` `200`, hôte inconnu `404`                                                                |
| 2026-08-10 | CORS en pré-vol (`OPTIONS`)                                                   | origine déclarée : `200` et `Access-Control-Allow-Origin` ; origine non déclarée : `403`                                             |
| 2026-08-10 | Chaîne ConfigMap → conteneur → Caddy → `/config.json`                         | la même URL d'API aux trois maillons, servie en `application/json` à travers l'Ingress                                               |
| 2026-08-10 | `deploy.sh` avec une image valide                                             | `0`, rollout en ~11 s                                                                                                                |
| 2026-08-10 | `deploy.sh` avec une image inexistante                                        | `3`, rollback automatique ; pod en service intact (`RESTARTS 0`), API à `200` pendant toute la fenêtre                               |
| 2026-08-10 | `rollback.sh -r <révision saine>`                                             | `0`, image rétablie                                                                                                                  |
| 2026-08-10 | Suppression du pod `back`, API sondée toutes les 150 ms                       | **16,1 s** d'indisponibilité totale de l'API (98 `503` sur 350) ; front non affecté ; données de démonstration rejouées              |
| 2026-08-10 | Deux déploiements successifs par l'overlay éphémère, namespace vierge         | 2 révisions par Deployment, **0 révision `PLACEHOLDER`**, annotation `last-applied-configuration` sur l'image réelle                 |
| 2026-08-10 | `rollback.sh` **sans** `--to-revision` (la commande de `rollback-production`) | `0` pour back et front, retour à la version précédente réellement déployée                                                           |
| 2026-08-10 | Même overlay appliqué deux fois                                               | second `apply` : `unchanged` ; aucune révision créée, aucun pod redémarré                                                            |
| 2026-08-10 | Disponibilité pendant un déploiement puis un rollback (180 s)                 | **99,75 %** sur **1 615** requêtes ; coupure maximale **≤ 0,20 s** ; latence médiane 13 ms                                           |
| 2026-09-22 | `deploy-staging` par la CI, images du registry GitLab                         | succès ; Secret du registry et `imagePullSecrets` exercés ([MONITORING.md](MONITORING.md) §9.1)                                      |
| 2026-09-23 | `deploy-production` par la CI                                                 | succès à 07:26 et 09:28 UTC                                                                                                          |
| 2026-09-23 | `rollback-production` en production                                           | succès à 13:34 UTC, puis redéploiement à 13:42 ; une première tentative à 13:01 a échoué sur un timeout du tunnel de l'agent GitLab  |
| 2026-10-05 | `deploy-production` du tag `v1.0.1`                                           | succès à 14:10 UTC : `back:1.0.1` (1 replica), `front:1.0.1` (2 replicas), `/actuator/health` à `UP` ([RELEASE.md](RELEASE.md) §7.5) |
| 2026-10-06 | `validate_k8s.sh --autotest` et `run_tests.sh`                                | 174 et 430 tests, 0 en échec                                                                                                         |

Le détail de ce que chaque ligne établit, et de ce qu'elle n'établit pas, suit.

### 14.3 Les sondes sous kubelet

Le pod `back` ne devient `Ready` qu'après le succès du `startupProbe`, et une ou
deux tentatives échouent réellement (`connection refused`) en attendant que la
JVM ouvre son port. C'est le comportement recherché au §5 : sans
`startupProbe`, ces échecs compteraient comme des échecs de _liveness_.

Les chiffres varient d'une exécution à l'autre, sur une machine identique et non
chargée : de 6,7 à 9,8 s de démarrage applicatif (±45 %), de 10 à 15 s jusqu'au
`Ready`. C'est un argument de plus contre un `initialDelaySeconds` fixe.

**Le budget de 150 s (30 × 5 s) est très surdimensionné pour cette machine :**
2 tentatives sur 30 sont consommées. Un nœud chargé mangerait la marge, et un
`startupProbe` trop court est une panne, pas un avertissement. Le prix est à
l'autre bout : une JVM bloquée au démarrage occupe un slot **150 s** avant
d'être abandonnée. Sur un cluster à un replica, le rollout n'avance pas
pendant ce temps. `failureThreshold: 20` (100 s) resterait 10 fois au-dessus du
besoin mesuré. La valeur actuelle est conservée faute de mesure sur une machine
lente, et faute de mesure avec l'agent OpenTelemetry sous la limite du pod
(§14.8).

### 14.4 L'Ingress et le CORS

L'addon `ingress` de minikube installe son IngressClass `nginx` avec
l'annotation `ingressclass.kubernetes.io/is-default-class: "true"` ; l'API
server renseigne donc le champ de l'Ingress lui-même, sans modification de la
base (§7).

**Méthode de test.** Sur macOS avec le driver `docker`, l'IP du nœud n'est pas
routable depuis l'hôte. Plutôt que `minikube tunnel`, qui réclame les privilèges
root pour se lier au port 80, un `kubectl port-forward` vers le contrôleur
suffit. Les hôtes étant fictifs, ils sont passés en en-tête `Host:` :

```shell
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80 &
curl -H "Host: api.microcrm.staging.example.com" http://127.0.0.1:18080/persons
```

La réponse `404` pour un hôte inconnu compte autant que les `200` : elle montre
que le routage se fait **par hôte** et non par défaut sur le premier service
venu. Le pré-vol CORS (`OPTIONS` avec `Origin:`) montre que
`MICROCRM_CORS_ALLOWED_ORIGINS` est réellement consommée par le back, et qu'elle
discrimine.

### 14.5 La chaîne ConfigMap → conteneur → Caddy → bundle

```shell
kubectl -n microcrm-staging get cm microcrm-config -o jsonpath='{.data.FRONT_API_BASE_URL}'
kubectl -n microcrm-staging exec deploy/front -- printenv FRONT_API_BASE_URL
curl -H "Host: microcrm.staging.example.com" http://127.0.0.1:18080/config.json
```

Les trois commandes rendent la même URL : la substitution
`{$FRONT_API_BASE_URL:…}` du Caddyfile est résolue au démarrage du conteneur, et
le fichier est servi en `application/json` à travers l'Ingress. C'est la preuve
d'exécution du §13 : **une seule image sert tous les environnements.**

### 14.6 `deploy.sh` et `rollback.sh` contre un vrai cluster

Les scripts sont testés à chaque commit contre le `kubectl` bouchonné de
`scripts/tests/stubs/` ; le cluster prouve ce que les bouchons ne peuvent pas.
Le scénario central est un déploiement d'image inexistante :

```
[…] INFO  Attente de la fin du rollout (timeout : 45s)
error: timed out waiting for the condition
[…] ERROR Le déploiement n'a pas abouti dans le temps prévu
[…] WARN  On revient automatiquement à la version précédente
deployment.apps/back rolled back
>>> CODE DE SORTIE = 3
```

Le pod en service n'est jamais touché : `maxUnavailable: 0` retire l'ancien pod
seulement une fois le nouveau `Ready`. Un déploiement raté ne coupe rien.

⚠️ **Limite : `rollback.sh` sans `--to-revision` juste après un échec de
`deploy.sh` redéploie l'image défaillante.** Le rollback automatique
(`kubectl rollout undo`) ne supprime pas la révision fautive : il en crée une
**nouvelle** portant l'image saine, et la révision « précédente » devient
l'image cassée. Le script signale l'échec en `3` et `maxUnavailable: 0` protège
encore le pod en service, mais la procédure de secours mène à un cul-de-sac.
**Après un échec de `deploy.sh`, lire `kubectl rollout history` et viser
explicitement une révision saine avec `-r`.** Une correction possible serait que
`rollback.sh` refuse de cibler une révision dont l'image est celle du dernier
rollout raté ; elle n'est pas faite.

⚠️ **Le résumé du Deployment ne révèle pas un rollout bloqué.** Pendant un
rollout qui n'aboutit pas, `kubectl get deploy` affiche `READY 1/1` : l'ancien
pod sain est compté. L'état réel se lit en listant les pods
(`ImagePullBackOff`) ou l'image du Deployment.

### 14.7 Résilience — perte de pod

Après suppression des pods `back` et `front`, les ReplicaSets créent des
remplaçants dans la seconde, `Ready` 10 à 15 s plus tard. Mesurée en continu, la
coupure de l'API est réelle :

```
10:14:52.408  200      <- dernier succès
10:14:53.534  503      <- pod supprimé
10:15:09.601  200      <- rétabli
```

Soit **16,1 s d'indisponibilité totale de l'API** (98 requêtes en `503` sur
350). C'est la conséquence directe du `replicas: 1` imposé par HSQLDB (§8.1) : à
un seul pod, rien n'absorbe la perte, et aucun `PodDisruptionBudget` ne protège
d'une éviction. Le back rejoue `InitialDataFixture` : **les données écrites
depuis son démarrage sont perdues.** Le front, statique et à plusieurs replicas
en production, n'est pas affecté.

`maxUnavailable: 0` protège les **déploiements** (§14.6), il ne protège pas
d'une **perte de pod**. Seule la première propriété est acquise ; la seconde
exige la sortie de HSQLDB.

### 14.8 Ce qui n'est pas vérifié

- **Le multi-nœud et l'ordonnancement.** Un nœud unique : ni éviction, ni
  contrainte de placement, ni comportement en pénurie de ressources.
- **Les valeurs de `resources`.** `metrics-server` n'est pas activé
  (`kubectl top` renvoie `Metrics API not available`) : requests et limits
  restent des estimations. Aucun `OOMKill` n'a été observé, ce qui est un
  indice, pas une mesure. Les traces OpenTelemetry mesurent la latence de l'API,
  pas la consommation des pods ; le seul chiffre de mémoire disponible est le
  surcoût de l'agent, mesuré une fois hors cluster (408 Mio contre 292,
  [MONITORING.md](MONITORING.md) §10.4).
- **Le TLS.** L'Ingress est en clair. Les URL de la ConfigMap sont en
  `https://` et servies telles quelles au navigateur : cohérent avec un
  environnement qui aurait un certificat, non exercé ici.
- **Le bundle Angular consommant `/config.json` dans un navigateur.** Le fichier
  est servi avec la bonne valeur ; que le navigateur le lise et appelle l'API
  est couvert par les tests front (`src/app/config.ts`), pas par le cluster.
- **L'échec du back interrompant le suivi du front** (§6) : déduit du
  mécanisme, non rejoué.
- **Les mesures fines (sondes, coupure, disponibilité)** ont été prises sur le
  chemin manuel, avec la fonction `build_deploy_overlay` extraite du pipeline ;
  les jobs de CI, eux, ne relèvent que leur succès ou leur échec.

### 14.9 Refaire la manipulation

```shell
kubectl create namespace microcrm-staging      # ou terraform apply (TERRAFORM.md)
TAG="t2-$(git rev-parse --short HEAD)"
docker build -t microcrm/back:$TAG ./back
docker build -t microcrm/front:$TAG ./front
minikube image load microcrm/back:$TAG
minikube image load microcrm/front:$TAG
minikube addons enable ingress

# Overlay éphémère portant le tag réel — c'est ce que fait build_deploy_overlay
# dans la CI (§6). Chemin RELATIF obligatoire : Kustomize refuse un chemin absolu.
mkdir -p .k8s-deploy-overlay
cat > .k8s-deploy-overlay/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../k8s/overlays/staging
images:
  - name: microcrm/back
    newName: microcrm/back
    newTag: $TAG
  - name: microcrm/front
    newName: microcrm/front
    newTag: $TAG
EOF
kubectl apply -k .k8s-deploy-overlay -n microcrm-staging
bash scripts/deploy/deploy.sh -n microcrm-staging -d back  -c back  -i microcrm/back:$TAG
bash scripts/deploy/deploy.sh -n microcrm-staging -d front -c front -i microcrm/front:$TAG

# Vérifier : historique sans PLACEHOLDER, routage par hôte, configuration du front
kubectl -n microcrm-staging rollout history deployment/back
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80 &
curl -H "Host: microcrm.staging.example.com"     http://127.0.0.1:18080/config.json
curl -H "Host: api.microcrm.staging.example.com" http://127.0.0.1:18080/persons

# Rollback, exactement comme rollback-production
bash scripts/deploy/rollback.sh -n microcrm-staging -d back -t 180s
```

Pour tout retirer sans toucher au reste du cluster :

```shell
kubectl delete namespace microcrm-staging
```

### 14.10 Révisions et rollback : vérification du mécanisme d'overlay

**Méthode.** Namespace `microcrm-staging` recréé à vide, pour que l'historique
des révisions parte de zéro. La fonction `build_deploy_overlay` est **extraite
de la configuration CI par un parseur YAML**, pas réécrite à la main, pour que
ce soit le code du pipeline qui soit éprouvé. Substitution locale :
`CI_REGISTRY_IMAGE=microcrm`, tag `t2-r1` puis `t2-r2`. L'API est interrogée en
continu à travers l'Ingress, à ~9 requêtes par seconde, pendant toute
l'opération.

**Historique après deux déploiements :**

```
--- deployment/back ---
   revision 1 -> microcrm/back:t2-r1
   revision 2 -> microcrm/back:t2-r2
--- deployment/front ---
   revision 1 -> microcrm/front:t2-r1
   revision 2 -> microcrm/front:t2-r2
```

Une révision et un ReplicaSet par déploiement, aucun `PLACEHOLDER`, et
l'annotation `last-applied-configuration` porte l'image réelle : c'est la cause
décrite au §6 qui est traitée, pas son symptôme. Sur le premier déploiement,
aucun pod ne passe par `ImagePullBackOff`, et `kubectl set image` n'affiche rien
(il n'imprime « image updated » que lorsqu'il modifie quelque chose) : l'étape 4
est bien un no-op.

**Rollback sans `--to-revision`**, commandes identiques à celles de
`rollback-production` : `rollback.sh` sort en `0` pour le back et le front, et
les deux Deployments reviennent sur `t2-r1`.

**Idempotence.** Le même overlay appliqué deux fois : le premier `apply` répond
`configured` (il réaligne l'annotation que le `rollout undo` a laissée sur
`t2-r2`), le second `unchanged`. Aucune révision créée, aucun pod redémarré.

**Disponibilité mesurée :**

| Grandeur                                 | Valeur mesurée               |
| ---------------------------------------- | ---------------------------- |
| Requêtes émises (180 s)                  | **1 615**                    |
| Réponses `200`                           | 1 611                        |
| Réponses non-`200`                       | 4 (1 × `502`, 3 × connexion) |
| Disponibilité                            | **99,75 %**                  |
| **Fenêtre d'indisponibilité _maximale_** | **0,20 s**                   |
| Latence médiane / max des `200`          | 13 ms / 266 ms               |

Sur les 11,5 s du second déploiement, un seul échantillon en erreur ; sur les
13,9 s du rollback, un seul. Le `502` vient de nginx au moment où l'ancien pod
back cède la place. Les trois échecs de connexion viennent du
`kubectl port-forward`, qui est l'appareil de mesure et non l'application ; deux
surviennent hors de toute opération. **Ce qui est établi : au plus 0,20 s de
coupure, et probablement moins.**

**Ce que ce chiffre ne prouve pas.** `maxUnavailable: 0` protège la
disponibilité quel que soit le contenu de l'historique ; l'overlay éphémère
garantit la **justesse de l'historique des révisions**, donc la fiabilité du
rollback. Les deux propriétés sont distinctes, et c'est la seconde que cette
vérification établit.
