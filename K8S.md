# Déploiement Kubernetes

Description de l'infrastructure de déploiement de MicroCRM : les manifestes du
dossier `k8s/`, la façon dont la CI les applique, et ce que cette première
version ne fait pas encore.

**État : les manifestes ont été appliqués sur un vrai cluster.** Le
2026-08-10, l'overlay `staging` a été déployé sur minikube v1.38.1
(Kubernetes v1.35.1, driver `docker`) dans le namespace `microcrm-staging` :
les deux Deployments ont atteint `rollout status` en `0`, les sondes ont été
observées sous kubelet, l'Ingress a routé ses deux hôtes depuis l'extérieur du
cluster, et le rollback automatique de `deploy.sh` a été déclenché sur un échec
réel. Le détail des commandes, des sorties et des mesures est au **§14**, avec
la liste de ce qui reste non vérifié.

Cette campagne a mis au jour un défaut réel dans la séquence de déploiement —
`kubectl apply -k` reposait l'image _placeholder_ à **chaque** application, pas
seulement sur un cluster vierge.

**Un audit de contre-vérification a ensuite rejoué toute la campagne** (2026-08-10).
Les conclusions du §14 sont confirmées, à trois réserves près, toutes documentées
à leur place :

- la conséquence la plus lourde du défaut n'avait pas été vue — **le job
  `rollback-production` ne pouvait pas fonctionner**, parce que la « révision
  précédente » d'un déploiement sain était toujours le placeholder (§14.6) ;
- la suppression d'un pod `back` provoque **16 s d'indisponibilité totale de
  l'API**, ce que le §14.7 ne disait pas (§14.7) ;
- l'affirmation du §6 selon laquelle un Deployment laissé sur le placeholder
  serait « à un `rollout restart` de l'indisponibilité » est **fausse** :
  l'ancien ReplicaSet le rattrape (§6).

**Ce défaut est corrigé.** Les jobs de déploiement composent désormais un overlay
Kustomize éphémère qui pose l'image réelle **avant** l'`apply` : l'état désiré
envoyé au cluster ne contient plus de placeholder, un déploiement n'insère plus
qu'une seule révision, et `rollback-production` ramène bien la version précédente
réellement déployée. Le mécanisme est décrit au **§6**, et vérifié sur cluster au
**§14.10** — deux déploiements successifs, zéro révision `PLACEHOLDER`, rollback
sans `--to-revision` en `0`, disponibilité mesurée à 99,75 % sur 1 615 requêtes.

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

## 6. Le déploiement : trois étapes, dans cet ordre

Les jobs `deploy-staging` et `deploy-production` enchaînent :

```yaml
- kubectl create secret docker-registry … | kubectl apply -f - # 1
- build_deploy_overlay staging # 2
- kubectl apply -k "$DEPLOY_OVERLAY_DIR" -n "$STAGING_NAMESPACE" # 3
- bash scripts/deploy/deploy.sh -n … -d "$APP_BACK_NAME" … # 4
```

**1. Le Secret du registry**, que les deux Deployments référencent en
`imagePullSecrets` (§12). Il vient d'abord parce que sans lui les pods créés à
l'étape 3 ne pourraient pas tirer leurs images d'un registry privé.

**2. `build_deploy_overlay`** fabrique un overlay Kustomize éphémère qui compose
l'overlay d'environnement et pose par-dessus le chemin de registry et le tag du
commit :

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
porte donc **directement la bonne image** : plus aucun placeholder ne quitte le
dépôt.

**4. `deploy.sh`** attend la fin du rollout et **revient automatiquement en
arrière** s'il n'aboutit pas dans `$DEPLOY_TIMEOUT`. Son `kubectl set image` est
désormais un **no-op** — l'étape 3 a déjà posé la bonne image — et il ne crée
donc aucune révision supplémentaire (vérifié, §14.10). On le garde pour l'attente
de rollout et pour le garde-fou, couverts par les 95 assertions de
`scripts/tests/run_tests.sh`.

### Pourquoi un overlay éphémère, et pas autre chose

Trois voies menaient au même résultat ; c'est la contrainte d'outillage qui a
tranché.

| Voie                             | Pourquoi elle n'a pas été retenue                                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `kustomize edit set image`       | `$KUBECTL_IMAGE` (`alpine/kubectl`) ne contient **que** le binaire `kubectl` — pas de `kustomize` autonome. Il faudrait figer une image d'outillage de plus. |
| `sed` sur le YAML rendu          | Réintroduit une substitution textuelle sur du YAML, c'est-à-dire le mécanisme de template que le choix de Kustomize cherchait à éviter (§2).                 |
| **Overlay éphémère + `images:`** | Le Kustomize **embarqué dans `kubectl`** suffit. Aucune image d'outillage supplémentaire, et la substitution reste structurée, pas textuelle.                |

Deux points d'implémentation méritent d'être notés, parce qu'ils ne sont pas
devinables :

- **Le répertoire doit être dans le dépôt, désigné par un chemin relatif.**
  Kustomize refuse un chemin absolu dans `resources` (`new root … cannot be
absolute`), donc un répertoire sous `/tmp` ne convient pas. Il vit en
  `.k8s-deploy-overlay/` et il est dans `.gitignore`.
- **Le préfixe `microcrm/` est une clé de correspondance.** C'est lui qui relie
  le transformateur `images:` aux manifestes ; s'il changeait d'un côté
  seulement, la substitution ne mordrait plus et le placeholder partirait tel
  quel. Il est donc nommé (`$K8S_PLACEHOLDER_IMAGE_PREFIX`) et un garde-fou du
  job échoue si le rendu contient encore `PLACEHOLDER`.

Les manifestes de `k8s/base/` gardent leur placeholder : c'est ce qui permet à
`lint-k8s` de les valider sans aucune coordonnée de registry, sur des branches
où les variables protégées ne sont pas disponibles (§4, §8.4).

### Le défaut que ce mécanisme corrige

> **Historique.** Ce document a longtemps décrit une séquence en deux commandes,
> `apply -k` puis `deploy.sh`, où l'image arrivait par `kubectl set image`. Cette
> section affirmait alors que « sur un cluster déjà déployé, `apply` ne change
> pas l'image posée par le déploiement précédent ». **C'était faux**, et la
> campagne du §14 l'a prouvé sur cluster.
>
> **La cause.** `kubectl set image` ne met pas à jour l'annotation
> `kubectl.kubernetes.io/last-applied-configuration` — celle-ci continuait de
> porter `PLACEHOLDER`. Or `kubectl apply` réécrit tout champ **présent** dans la
> configuration désirée ; l'annotation ne sert qu'à détecter les champs
> _supprimés_. Chaque `apply -k` reposait donc `PLACEHOLDER` sur un déploiement
> pourtant sain.
>
> **La conséquence, et c'est la plus grave.** Chaque déploiement insérait **deux**
> révisions : une à `PLACEHOLDER` posée par `apply`, une à la vraie image posée
> par `set image`. La « révision précédente » d'un déploiement sain était donc
> **toujours le placeholder**. Or `rollback-production` appelle `rollback.sh`
> sans `--to-revision` et sans moyen d'en passer un : **le seul filet de sécurité
> du pipeline aurait cassé la production au lieu de la réparer.**
>
> **Ce que la disponibilité ne révélait pas.** `maxUnavailable: 0` masquait
> entièrement le problème : les anciens pods n'étant retirés qu'une fois les
> nouveaux `Ready` — ce qui n'arrivait jamais avec le placeholder — le service
> restait servi. Mesuré à l'époque : 440 requêtes API et 456 requêtes front
> pendant la fenêtre, **toutes en `200`**. Un défaut peut être invisible en
> disponibilité et grave en exploitabilité ; c'est le principal enseignement de
> cet épisode.

Avec l'overlay éphémère, l'état désiré et l'annotation portent la même image
réelle. Un déploiement insère **une seule** révision, et la révision précédente
est la version précédente réellement déployée. `rollback-production` redevient
ce qu'il prétend être. Vérifié de bout en bout au §14.10.

### Ce qui disparaît, et ce qui reste

La fenêtre d'`ImagePullBackOff` entre les deux commandes **n'existe plus** :
l'`apply` crée directement des pods avec la bonne image. Le premier déploiement
sur un cluster vierge se déroule sans aucun pod en erreur (§14.10).

L'effet de bord de l'ordre des jobs est lui aussi très atténué. Les jobs
appliquent l'overlay **une fois** puis appellent `deploy.sh` **deux fois, en
série** : le back d'abord, le front ensuite. Si le back échoue, `deploy.sh` sort
en `3`, le job s'arrête et la seconde commande n'est jamais exécutée. Auparavant
le Deployment `front` restait sur `microcrm/front:PLACEHOLDER` ; désormais
l'étape 3 lui a **déjà posé la bonne image** — vérifié, un seul `apply` suffit à
mettre les deux Deployments sur l'image du commit. Ce qui manque alors n'est plus
un état désiré faux, mais seulement l'**observation** de son rollout : personne
n'attend le front ni ne le ramène en arrière s'il échoue. _(Cette dernière
conséquence est déduite du mécanisme, elle n'a pas été rejouée en provoquant un
échec du back.)_

`deploy-staging` porte en outre `allow_failure: true` : en staging, cette
situation ne fait pas échouer le pipeline.

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

## 14. La campagne de déploiement réel (2026-08-10)

Cette section est le compte rendu de la première application des manifestes sur
un cluster. Elle remplace l'avertissement « jamais appliqué » qui ouvrait ce
document. Tout ce qui suit a été **observé**, pas déduit ; ce qui n'a pas pu
l'être est listé au §14.8.

### 14.1 L'environnement

| Élément    | Valeur                                                  |
| ---------- | ------------------------------------------------------- |
| Cluster    | minikube v1.38.1, driver `docker`, nœud unique `Ready`  |
| Kubernetes | v1.35.1 (client `kubectl` v1.36.2)                      |
| Namespace  | `microcrm-staging`, créé pour l'occasion                |
| Overlay    | `k8s/overlays/staging`                                  |
| Images     | `microcrm/back:t2-bd4987d`, `microcrm/front:t2-bd4987d` |
| Kustomize  | celui embarqué dans `kubectl` (`kubectl apply -k`)      |
| Contrôleur | ingress-nginx v1.14.3 (addon `ingress` de minikube)     |

**Livraison des images : `minikube image load`**, et non le registry local. Un
registry minikube sans authentification n'aurait pas exercé davantage le chemin
`imagePullSecrets` — le seul point que le déploiement local pouvait apprendre sur
ce sujet — tout en ajoutant une configuration TLS à régler. Les tags sont
explicites et immuables (`t2-<sha court>`), jamais `latest`, conformément à
l'assertion de `validate_k8s.sh` sur les tags mobiles.

### 14.2 Le rollout

```
$ kubectl apply -k k8s/overlays/staging -n microcrm-staging
configmap/microcrm-config created
service/back created
service/front created
deployment.apps/back created
deployment.apps/front created
ingress.networking.k8s.io/microcrm created

$ kubectl -n microcrm-staging rollout status deployment/back --timeout=180s
deployment "back" successfully rolled out          # code 0, 10,5 s

$ kubectl -n microcrm-staging rollout status deployment/front --timeout=180s
deployment "front" successfully rolled out         # code 0
```

C'est le critère de validation de la tâche, et il est rempli.

### 14.3 Les sondes sous kubelet — le `startupProbe` fait bien son travail

Le point que seul un vrai kubelet pouvait trancher. Chronologie du pod `back`,
reconstituée à partir des évènements et des logs du conteneur :

| Instant (UTC) | Évènement                                                               |
| ------------- | ----------------------------------------------------------------------- |
| `09:59:14`    | `Started` — le conteneur démarre                                        |
| `09:59:18`    | **`Unhealthy` : `Startup probe failed: … connect: connection refused`** |
| `09:59:21.3`  | `Tomcat started on port 8080`                                           |
| `09:59:21.7`  | `Started MicroCRMApplication in 7.123 seconds`                          |
| `09:59:23`    | condition `Ready` du pod passe à `True`                                 |

**Le pod n'est devenu `Ready` qu'après le succès du `startupProbe`**, et une
tentative a réellement échoué en attendant que la JVM ouvre son port. C'est
exactement le comportement recherché au §5 : sans `startupProbe`, cette même
seconde 18 aurait compté comme un échec de _liveness_.

Mesure refaite après suppression du pod (§14.7) : `6,713 s` de démarrage
applicatif, `Ready` 10 s après le démarrage du conteneur. Les deux mesures
concordent.

Une troisième mesure, prise à l'audit sur la même machine, donne un résultat
sensiblement plus lent — utile à connaître, car elle borne la confiance à
accorder aux deux premières :

| Repère                        | Instant    | Écart au `Started` |
| ----------------------------- | ---------- | ------------------ |
| `Started` (conteneur)         | `10:14:54` | —                  |
| `Startup probe failed` (1)    | `10:14:58` | +4 s               |
| `Startup probe failed` (2)    | `10:15:03` | +9 s               |
| `Tomcat started on port 8080` | `10:15:04` | +10 s              |
| `Started MicroCRMApplication` | `9,838 s`  | +10,6 s            |
| condition `Ready`             | `10:15:09` | **+15 s**          |

La **forme** est donc stable et c'est elle qui compte : le `startupProbe` échoue
d'abord, et le pod ne devient `Ready` qu'après son succès. Les **chiffres**, eux,
varient de 6,7 s à 9,8 s de démarrage applicatif (±45 %) et de 10 s à 15 s
jusqu'au `Ready`, d'une exécution à l'autre, sur une machine pourtant identique
et non chargée. Ce sont des sondages, pas des constantes.

Cette variance renforce l'argument du §5 plutôt qu'elle ne l'affaiblit : si le
délai bouge de moitié sans qu'aucune variable ne change, c'est bien qu'un
`initialDelaySeconds` fixe serait le mauvais outil. Le nombre de tentatives
consommées reste stable (2 sur 30) et la marge reste d'un ordre de grandeur.

**Le budget de 150 s (30 × 5 s) est très surdimensionné pour cette machine :**
2 tentatives sur 30 sont consommées, soit 10 s sur 150. Ce n'est pas un défaut —
un nœud chargé ou un poste plus lent mangerait la marge, et un `startupProbe`
trop court est une panne, pas un avertissement. Le vrai prix à connaître est
l'autre bout : une JVM réellement bloquée au démarrage occupera un slot pendant
**150 s** avant d'être abandonnée. Sur un cluster à un replica, c'est 150 s
pendant lesquelles le rollout n'avance pas. `failureThreshold: 20` (100 s)
resterait 10 fois au-dessus du besoin mesuré tout en raccourcissant le pire cas ;
la valeur actuelle est conservée faute de mesure sur une machine lente.

### 14.4 L'Ingress — les deux hôtes routent

**Aucun `ingressClassName` n'a été nécessaire, et la base n'a pas été modifiée.**
L'addon `ingress` de minikube installe son IngressClass `nginx` avec
l'annotation `ingressclass.kubernetes.io/is-default-class: "true"` ; l'API
server a donc renseigné le champ elle-même :

```
$ kubectl -n microcrm-staging get ingress microcrm
NAME       CLASS   HOSTS                                                           ADDRESS        PORTS
microcrm   nginx   microcrm.staging.example.com,api.microcrm.staging.example.com   192.168.49.2   80
```

Le commentaire de `k8s/base/ingress.yaml` (« à ajouter dans les overlays le jour
où il sera connu ») reste juste **en principe** : un cluster sans IngressClass
par défaut refuserait l'Ingress. Le champ appartient alors à l'overlay, pas à la
base — le contrôleur est une propriété du cluster cible, donc de
l'environnement.

**Méthode de test.** Sur macOS avec le driver `docker`, l'IP du nœud
(`192.168.49.2`) n'est pas routable depuis l'hôte — vérifié, `curl` sur cette
adresse expire. Plutôt que `minikube tunnel`, qui réclame les privilèges root
pour se lier au port 80, un `kubectl port-forward` vers le contrôleur suffit et
ne demande aucun privilège. Les hôtes étant fictifs, ils sont passés en en-tête
`Host:` — `/etc/hosts` n'aurait rien apporté de plus et demandait `sudo` :

```shell
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80 &
```

| Requête                                               | Résultat observé                                 |
| ----------------------------------------------------- | ------------------------------------------------ |
| `Host: microcrm.staging.example.com` → `/`            | `200`, `text/html`, le `<title>MicroCRM</title>` |
| `Host: api.microcrm.staging.example.com` → `/`        | `200`, `application/hal+json`, index HAL         |
| `Host: api.microcrm.staging.example.com` → `/persons` | `200`, la fixture `John Doe`                     |
| `Host: inconnu.example.com` → `/`                     | `404` (default backend)                          |

La dernière ligne compte autant que les autres : elle montre que le routage se
fait bien **par hôte** et non par défaut sur le premier service venu.

Le CORS a été vérifié dans la foulée, puisque les deux origines diffèrent (§7) :

```
$ curl -X OPTIONS -H "Host: api.microcrm.staging.example.com" \
       -H "Origin: https://microcrm.staging.example.com" \
       -H "Access-Control-Request-Method: GET" …/persons
HTTP/1.1 200
Access-Control-Allow-Origin: https://microcrm.staging.example.com
Access-Control-Allow-Methods: GET,POST,PATCH,DELETE

# origine non déclarée
$ curl -X OPTIONS -H "Origin: https://evil.example.com" … → 403
```

`MICROCRM_CORS_ALLOWED_ORIGINS` de la ConfigMap est donc réellement consommée
par le back, et elle discrimine.

### 14.5 La chaîne ConfigMap → conteneur → Caddy → bundle

Les quatre maillons, vérifiés bout à bout :

```
$ kubectl -n microcrm-staging get cm microcrm-config -o jsonpath='{.data}'
{"FRONT_API_BASE_URL":"https://api.microcrm.staging.example.com", …}

$ kubectl -n microcrm-staging exec deploy/front -- printenv FRONT_API_BASE_URL
https://api.microcrm.staging.example.com

$ curl -H "Host: microcrm.staging.example.com" …/config.json
{"apiBaseUrl":"https://api.microcrm.staging.example.com"}
```

La substitution `{$FRONT_API_BASE_URL:…}` du Caddyfile est donc bien résolue au
démarrage du conteneur, et le fichier est servi en `application/json` au travers
de l'Ingress. C'est la preuve d'exécution qui manquait au §13 : **une seule image
sert tous les environnements.** L'URL pointe sur `*.staging.example.com` parce
que l'overlay `staging` le demande — ce n'est pas une anomalie.

### 14.6 `deploy.sh` et `rollback.sh` contre un vrai cluster

Jusqu'ici ces scripts n'avaient été exercés que contre le `kubectl` bouchonné de
`scripts/tests/stubs/`. Quatre exécutions réelles :

| Scénario                                   | Code | Observé                               |
| ------------------------------------------ | ---- | ------------------------------------- |
| `deploy.sh` avec une image valide          | `0`  | rollout complet en ~11 s              |
| `deploy.sh` avec une image **inexistante** | `3`  | **rollback automatique déclenché**    |
| `rollback.sh` sans `--to-revision`         | `3`  | voir l'avertissement ci-dessous       |
| `rollback.sh -r <révision saine>`          | `0`  | image rétablie, pod servant à nouveau |

Le scénario central, celui que les stubs ne pouvaient pas prouver :

```
[…] INFO  Déploiement de microcrm/back:tag-qui-nexiste-pas sur microcrm-staging/back
deployment.apps/back image updated
[…] INFO  Attente de la fin du rollout (timeout : 45s)
Waiting for deployment "back" rollout to finish: 1 old replicas are pending termination...
error: timed out waiting for the condition
[…] ERROR Le déploiement n'a pas abouti dans le temps prévu
[…] WARN  On revient automatiquement à la version précédente
deployment.apps/back rolled back
>>> CODE DE SORTIE = 3
```

L'image saine était rétablie ensuite, et **le pod en service n'a jamais été
touché** : `RESTARTS 0`, âge inchangé, API à `200` pendant toute la fenêtre. Le
`maxUnavailable: 0` tient ses promesses — un déploiement raté ne coupe rien.

> **Défaut constaté — `rollback.sh` sans `--to-revision` juste après un échec.**
> Le rollback automatique de `deploy.sh` (`kubectl rollout undo`) ne supprime pas
> la révision fautive : il en crée une **nouvelle** portant l'image saine. La
> révision « précédente » devient donc l'image cassée. Enchaîner `rollback.sh`
> sans argument, ce que la procédure de secours invite naturellement à faire,
> **redéploie l'image défaillante** :
>
> ```
> $ bash scripts/deploy/rollback.sh -n microcrm-staging -d back -t 40s
> […] INFO  Rollback de microcrm-staging/back vers la révision précédente
> error: timed out waiting for the condition
> >>> CODE DE SORTIE = 3
> $ kubectl -n microcrm-staging get deploy back -o jsonpath='{…image}'
> microcrm/back:tag-qui-nexiste-pas
> ```
>
> Le script se comporte correctement — il signale l'échec en `3` et
> `maxUnavailable: 0` protège encore le pod en service. Mais la procédure de
> secours mène à un cul-de-sac. **Réflexe à retenir : après un échec de
> `deploy.sh`, lire `kubectl rollout history` et viser explicitement une révision
> saine avec `-r`.** Une correction possible serait que `rollback.sh` refuse de
> cibler une révision dont l'image est identique à celle du dernier rollout raté ;
> elle n'est pas faite dans ce lot.

`kubectl rollout undo` émet par ailleurs un avertissement sur l'annotation
`last-applied-configuration` non mise à jour. Il est de la même famille que le
défaut du §6 et pointe la même cause : `set image` et `apply` ne tiennent pas le
même registre de l'état désiré.

> **Défaut plus grave, constaté à l'audit — le job `rollback-production` ne peut
> pas fonctionner.** ⚠️ _Ce défaut a depuis été **corrigé** ; le constat
> ci-dessous décrit l'état antérieur et reste consigné parce qu'il explique
> pourquoi le mécanisme du §6 a changé. La vérification du correctif est au
> §14.10._
>
> Le défaut du §6 n'abîme pas seulement le rollback qui suit
> un déploiement _raté_ : il casse le rollback qui suit un déploiement
> **réussi**, c'est-à-dire le cas d'usage même du job `rollback-production`.
>
> Chaque déploiement CI insère **deux** révisions, dans cet ordre : `apply -k`
> en crée une portant `PLACEHOLDER`, puis `deploy.sh` en crée une seconde
> portant la vraie image. La « révision précédente » d'un déploiement sain est
> donc toujours le `PLACEHOLDER`, jamais la version d'avant :
>
> ```
> $ kubectl -n microcrm-staging rollout history deployment/back
> revision 10 -> microcrm/back:PLACEHOLDER
> revision 11 -> microcrm/back:t2-bd4987d      # courante, saine
>
> $ bash scripts/deploy/rollback.sh -n microcrm-staging -d back -t 40s
> [...] INFO  Rollback de microcrm-staging/back vers la révision précédente
> deployment.apps/back rolled back
> error: timed out waiting for the condition
> >>> CODE DE SORTIE = 3
> $ kubectl -n microcrm-staging get deploy back -o jsonpath='{…image}'
> microcrm/back:PLACEHOLDER
> ```
>
> Or `rollback-production` exécute exactement `rollback.sh -n … -d … -t …`,
> **sans `-r` et sans moyen d'en passer un**. Le seul geste de secours prévu par
> le pipeline ne peut donc jamais atteindre la version précédente : il vise une
> image inexistante, échoue en `3`, et laisse le Deployment sur `PLACEHOLDER`.
> `maxUnavailable: 0` évite la coupure (402 requêtes API mesurées, toutes en
> `200`), mais la capacité de retour arrière est **nulle** tant que le défaut du
> §6 n'est pas corrigé.
>
> Corollaire : `revisionHistoryLimit: 3` est de fait divisé par deux, puisqu'une
> révision sur deux est un `PLACEHOLDER`. La profondeur réelle de rollback est
> d'environ un déploiement.
>
> Dernier angle mort : pendant tout ce temps `kubectl get deploy` affiche
> `READY 1/1  UP-TO-DATE 1  AVAILABLE 1` — l'ancien pod sain est compté. L'état
> cassé ne se voit qu'en listant les pods (`ImagePullBackOff`) ou en lisant
> l'image du Deployment. Une supervision branchée sur le résumé du Deployment ne
> lèverait aucune alerte.

### 14.7 Résilience — suppression de pod

```
$ kubectl -n microcrm-staging delete pod back-b6df7cd44-f2hkl front-68bb555464-qxdwm
pod "back-b6df7cd44-f2hkl" deleted
pod "front-68bb555464-qxdwm" deleted
```

Les deux ReplicaSets ont créé des remplaçants **immédiatement** (`Pending` dans
la seconde qui suit), `Ready` 10 à 15 s plus tard, et le service était rétabli :
API et front à `200`. Le back a rejoué `InitialDataFixture` — conséquence directe
et attendue de la base en mémoire (§8.1) : **la suppression d'un pod back perd
les données écrites depuis son démarrage.** La résilience porte sur la
disponibilité du processus, pas sur celle des données.

> **Précision apportée à l'audit — il y a bien une coupure, et elle se mesure.**
> La formulation ci-dessus décrit l'état avant et après, mais pas l'intervalle.
> Rejoué en interrogeant l'API en continu (une requête toutes les 150 ms)
> pendant la suppression du pod `back` :
>
> ```
> 10:14:52.408  200      <- dernier succès
> 10:14:53.534  503      <- pod supprimé
> 10:15:09.601  200      <- rétabli
> ```
>
> Soit **16,1 s d'indisponibilité totale de l'API** (98 requêtes en `503` sur
> 350). C'est la conséquence directe du `replicas: 1` imposé par HSQLDB (§8.1) :
> à un seul pod, il n'y a rien pour absorber la perte, et aucun
> `PodDisruptionBudget` ne protège d'une éviction. Le front, statique et
> indépendant, n'a pas été affecté.
>
> À retenir : `maxUnavailable: 0` protège les **déploiements** (§6, §14.6), il
> ne protège pas d'une **perte de pod**. Ce sont deux propriétés distinctes, et
> seule la première est acquise ici. La seconde exige la sortie de HSQLDB.

### 14.8 Ce que ce déploiement n'a pas vérifié

- **Le registry privé et son `imagePullSecrets`.** Le Secret `gitlab-registry`
  n'existe pas sur minikube ; le kubelet émet alors un avertissement — observé,
  répété 5 fois sur 59 s — et **poursuit** :

  ```
  Warning  FailedToRetrieveImagePullSecret  kubelet
    Unable to retrieve some image pull secrets (gitlab-registry);
    attempting to pull the image may not succeed.
  ```

  Le pod démarre quand même parce que l'image est déjà présente sur le nœud
  (`Container image "…" already present on machine`) et que
  `imagePullPolicy: IfNotPresent` n'exige alors aucun tirage. **Ce n'est donc pas
  une preuve que le chemin registry privé fonctionne** — il reste non testé, et
  ne le sera que face à un vrai registry authentifié.

- **La production.** Seul l'overlay `staging` a été appliqué. L'overlay
  `production` n'est vérifié que par construction Kustomize et par les assertions
  de `validate_k8s.sh`.

- **Le multi-nœud et l'ordonnancement.** Un nœud unique : ni éviction, ni
  contrainte de placement, ni comportement en pénurie de ressources.

- **Les valeurs de `resources`.** `metrics-server` n'est pas activé
  (`kubectl top` renvoie `Metrics API not available`), donc les requests et
  limits du §11 restent des estimations. Aucun `OOMKill` n'a été observé, ce qui
  est un indice, pas une mesure.

- **Le TLS.** L'Ingress est en clair. Les URL de la ConfigMap sont en `https://`
  et sont servies telles quelles au navigateur : cohérent avec un environnement
  qui aurait un certificat, non exercé ici.

- **Le bundle Angular consommant réellement `/config.json`.** Le fichier est
  servi avec la bonne valeur, ce qui est le maillon que le cluster pouvait
  prouver. Que le navigateur le lise et appelle l'API est couvert par les tests
  front (`src/app/config.ts`), pas par ce déploiement.

- **La CI appliquant ces manifestes.** Les jobs `deploy-staging` /
  `deploy-production` n'ont pas tourné : le déploiement a été fait à la main avec
  les mêmes commandes qu'eux, depuis un poste, avec `KUBECONFIG` positionné.

### 14.9 Refaire la manipulation

```shell
kubectl create namespace microcrm-staging
docker build -t microcrm/back:t2-$(git rev-parse --short HEAD) ./back
docker build -t microcrm/front:t2-$(git rev-parse --short HEAD) ./front
minikube image load microcrm/back:t2-$(git rev-parse --short HEAD)
minikube image load microcrm/front:t2-$(git rev-parse --short HEAD)
minikube addons enable ingress

# Overlay éphémère portant le tag réel — c'est ce que fait build_deploy_overlay
# dans la CI (§6). Chemin RELATIF obligatoire : Kustomize refuse un chemin absolu.
TAG="t2-$(git rev-parse --short HEAD)"
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
export KUBECONFIG="$HOME/.kube/config"
bash scripts/deploy/deploy.sh -n microcrm-staging -d back  -c back  \
  -i microcrm/back:t2-$(git rev-parse --short HEAD)
bash scripts/deploy/deploy.sh -n microcrm-staging -d front -c front \
  -i microcrm/front:t2-$(git rev-parse --short HEAD)

kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80 &
curl -H "Host: microcrm.staging.example.com"     http://127.0.0.1:18080/config.json
curl -H "Host: api.microcrm.staging.example.com" http://127.0.0.1:18080/persons
```

Pour tout retirer sans toucher au reste du cluster :

```shell
kubectl delete namespace microcrm-staging
```

### 14.10 Seconde campagne — vérification du correctif (2026-08-10)

Cette campagne valide le mécanisme d'overlay éphémère décrit au §6. Namespace
`microcrm-staging` **recréé à vide** pour que l'historique des révisions parte de
zéro et ne doive rien à la campagne précédente. Les commandes rejouent
fidèlement celles des jobs, avec la fonction `build_deploy_overlay` **extraite du
`.gitlab-ci.yml` par un parseur YAML** — pas réécrite à la main — pour que ce
soit bien le code du pipeline qui soit éprouvé.

Substitution locale : `CI_REGISTRY_IMAGE=microcrm` et `CI_COMMIT_SHORT_SHA=t2-r1`
puis `t2-r2`, faute de registry GitLab sur ce poste.

#### L'overlay produit

```
$ build_deploy_overlay staging
Overlay éphémère (staging) :
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../k8s/overlays/staging
images:
  - name: microcrm/back
    newName: microcrm/back
    newTag: t2-r1
  - name: microcrm/front
    newName: microcrm/front
    newTag: t2-r1
```

#### Premier déploiement — plus aucun `ImagePullBackOff`

```
$ kubectl apply -k .k8s-deploy-overlay -n microcrm-staging
configmap/microcrm-config created
service/back created
service/front created
deployment.apps/back created
deployment.apps/front created
ingress.networking.k8s.io/microcrm created

$ bash scripts/deploy/deploy.sh -n microcrm-staging -d back -c back -i microcrm/back:t2-r1 -t 180s
[…] INFO  Déploiement de microcrm/back:t2-r1 sur microcrm-staging/back (conteneur : back)
[…] INFO  Attente de la fin du rollout (timeout : 180s)
Waiting for deployment "back" rollout to finish: 0 of 1 updated replicas are available...
deployment "back" successfully rolled out
[…] INFO  Déploiement réussi : microcrm-staging/back -> microcrm/back:t2-r1
EXIT_BACK=0
```

Deux choses à relever dans cette sortie. D'abord, sur un cluster vierge, **aucun
pod n'est passé par `ImagePullBackOff`** — la fenêtre décrite par l'ancienne
version du §6 a disparu. Ensuite, `kubectl set image` n'a **rien affiché** : il
n'imprime « image updated » que lorsqu'il modifie quelque chose. C'est la
première indication que l'étape 4 est devenue un no-op.

État après ce seul déploiement :

```
$ kubectl -n microcrm-staging rollout history deployment/back
REVISION  CHANGE-CAUSE
1         <none>
   rev 1 -> microcrm/back:t2-r1

$ kubectl -n microcrm-staging get rs \
    -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,IMAGE:…'
back-fb5c8fcd9     1   microcrm/back:t2-r1
front-849b9c9597   1   microcrm/front:t2-r1

$ # l'annotation porte-t-elle la vraie image ? (c'est la cause racine du défaut)
$ kubectl -n microcrm-staging get deploy back \
    -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | …
microcrm/back:t2-r1
```

**Une seule révision, un seul ReplicaSet, et l'annotation
`last-applied-configuration` porte la vraie image.** C'est la correction de la
cause racine, pas de son symptôme.

#### Second déploiement — le critère principal

Après un second déploiement complet au tag `t2-r2` :

```
$ # historique des deux Deployments, révision par révision
--- deployment/back ---
   revision 1 -> microcrm/back:t2-r1
   revision 2 -> microcrm/back:t2-r2
--- deployment/front ---
   revision 1 -> microcrm/front:t2-r1
   revision 2 -> microcrm/front:t2-r2

$ # inventaire des images portées par TOUS les ReplicaSets du namespace
   1 microcrm/back:t2-r1
   1 microcrm/back:t2-r2
   1 microcrm/front:t2-r1
   1 microcrm/front:t2-r2
```

**Deux déploiements, deux révisions, zéro révision `PLACEHOLDER`.** Sous
l'ancien mécanisme il y en aurait eu quatre, dont deux placeholders. Le critère
principal est rempli.

#### Le rollback réparé — la preuve qui compte

Commandes strictement identiques à celles du job `rollback-production`, c'est-à-dire
**sans `--to-revision`** :

```
$ bash scripts/deploy/rollback.sh -n microcrm-staging -d back -t 180s
[…] INFO  Rollback de microcrm-staging/back vers la révision précédente
deployment.apps/back rolled back
[…] INFO  Attente de la stabilisation (timeout : 180s)
deployment "back" successfully rolled out
[…] INFO  Rollback réussi : microcrm-staging/back
EXIT_BACK=0

$ bash scripts/deploy/rollback.sh -n microcrm-staging -d front -t 180s
[…] INFO  Rollback réussi : microcrm-staging/front
EXIT_FRONT=0

$ kubectl -n microcrm-staging get deploy -o jsonpath='{…}'
back=microcrm/back:t2-r1
front=microcrm/front:t2-r1
```

**Les deux scripts sortent en `0` et ramènent `t2-r1`** — la version précédente
réellement déployée, et non un placeholder. C'est exactement ce que
`rollback-production` doit faire, et ce qu'il ne faisait pas.

#### Idempotence

Le même overlay appliqué deux fois de suite, sans redéploiement entre les deux :

```
--- apply n°1 ---
deployment.apps/back configured
deployment.apps/front configured
--- apply n°2 ---
deployment.apps/back unchanged
deployment.apps/front unchanged

$ kubectl -n microcrm-staging get deploy back -o jsonpath='generation / observedGeneration'
generation=4 observed=4
$ kubectl -n microcrm-staging get pods
back-fb5c8fcd9-phsv4     1/1  Running  0  37s
front-849b9c9597-9qvsq   1/1  Running  0  26s
```

Aucune révision créée, aucun pod redémarré (`RESTARTS 0`, âges inchangés). Le
`configured` du premier `apply` ne fait que réaligner l'annotation
`last-applied-configuration`, que le `rollout undo` précédent avait laissée sur
`t2-r2` — `kubectl` prévient d'ailleurs explicitement de cet écart à chaque
`rollout undo`. Le second `apply` répond `unchanged` : le système est stable.

#### La coupure, mesurée et non décrite

Reproche fondé adressé à la première campagne : une fenêtre d'indisponibilité
**se mesure**, elle ne se déduit pas de ses extrémités. L'API a donc été
interrogée en continu à travers l'Ingress pendant toute l'opération, à ~9 requêtes
par seconde.

| Grandeur                                 | Valeur mesurée               |
| ---------------------------------------- | ---------------------------- |
| Requêtes émises (180 s)                  | **1 615**                    |
| Réponses `200`                           | 1 611                        |
| Réponses non-`200`                       | 4 (1 × `502`, 3 × connexion) |
| Disponibilité                            | **99,75 %**                  |
| **Fenêtre d'indisponibilité _maximale_** | **0,20 s**                   |
| Latence médiane / max des `200`          | 13 ms / 266 ms               |

Le détail des échecs consécutifs, qui est la seule lecture honnête d'une
coupure :

```
t+ 24.81s : 2 échantillons, durée <= 0,20s, codes=[502, 0]   <- bascule du pod back (fin du déploiement n°2)
t+ 62.34s : 1 échantillon,  durée <= 0,10s, codes=[0]
t+ 65.52s : 1 échantillon,  durée <= 0,10s, codes=[0]
```

Sur les 11,5 s du second déploiement : **un seul échantillon en erreur**. Sur les
13,9 s du rollback : **un seul**. Il n'y a donc pas de « fenêtre de coupure » au
sens habituel, mais un raté isolé de deux échantillons au moment où l'ancien pod
back cède la place.

**Attribution, à ne pas surinterpréter.** Le `502` vient de nginx : le backend
était réellement indisponible à cet instant. Les trois `code=0` sont des échecs
de connexion à mon `kubectl port-forward`, qui est l'appareil de mesure et non
l'application — `port-forward` est connu pour laisser tomber des connexions. Les
deux derniers surviennent d'ailleurs hors de toute opération. **Ce qui est établi
est donc : au plus 0,20 s, et probablement moins.**

**Ce que ce chiffre ne prouve pas.** Il ne montre aucune amélioration apportée
par le correctif sur la disponibilité, et il ne faut pas le lire ainsi :
l'ancien mécanisme ne coupait pas non plus (440 requêtes toutes en `200`, §6).
`maxUnavailable: 0` protégeait déjà le service. **Le correctif porte sur la
justesse de l'historique des révisions, donc sur la fiabilité du rollback — pas
sur la disponibilité.**

#### Les suites de tests

```
$ bash scripts/tests/validate_k8s.sh --autotest   -> 60 test(s) OK, 0 en échec   (exit 0)
$ bash scripts/tests/run_tests.sh                 -> 95 test(s) OK, 0 en échec   (exit 0)
```

`validate_k8s.sh` continue de valider `k8s/base/` et les overlays, qui gardent
leur placeholder : le correctif ne déplace rien dans les manifestes. Les 95
assertions de `run_tests.sh` couvrent toujours `deploy.sh` et `rollback.sh`, que
ce lot n'a pas modifiés.

#### Ce que cette seconde campagne n'a pas vérifié

- **Le vrai registry privé.** Toujours pas de registry GitLab : `newName` a été
  substitué par `microcrm`, pas par un `$CI_REGISTRY_IMAGE` réel. Le rendu de
  l'overlay est identique en forme, mais **le tirage d'image authentifié reste
  non testé**, comme au §14.8.
- **Les jobs eux-mêmes.** C'est la fonction `build_deploy_overlay` extraite du
  `.gitlab-ci.yml` qui a été exécutée, dans un shell local — pas un runner GitLab
  dans l'image `alpine/kubectl`. Le fait que cette image ne contienne que
  `kubectl` a été vérifié par ailleurs, et le mécanisme n'utilise rien d'autre.
- **L'échec du back interrompant le déploiement du front.** Conséquence déduite
  au §6, non rejouée.
- **La production.** Seul l'overlay `staging` a été appliqué ; `deploy-production`
  reçoit la même correction mais n'a pas été exécuté.
