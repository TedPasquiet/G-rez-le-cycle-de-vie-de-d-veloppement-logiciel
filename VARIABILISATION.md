# Variabilisation de la CI/CD

Ce document décrit quelles valeurs sont externalisées, où elles vivent, et
pourquoi d'autres restent volontairement dans le code. Le déploiement Kubernetes
qui les consomme est décrit dans [K8S.md](K8S.md).

## 1. Le principe

**Variabiliser** = sortir du code toute valeur qui dépend du _contexte
d'exécution_, et l'injecter depuis l'extérieur (variable CI, variable
d'environnement, argument de script).

Le critère de décision, à appliquer sur chaque valeur littérale :

> Est-ce que cette valeur serait différente sur un autre environnement, un autre
> projet, ou dans six mois ?

Si oui → variable. Si non (une règle métier, un choix de politique), elle reste
dans le code : une constante qu'on peut désactiver depuis l'interface CI n'est
plus une garantie.

Trois motivations, par ordre d'importance :

| Motivation         | Ce qu'on évite                                                              |
| ------------------ | --------------------------------------------------------------------------- |
| **Sécurité**       | un secret commité reste dans l'historique Git pour toujours                 |
| **Portabilité**    | un artefact qui ne fonctionne que sur l'environnement où il a été construit |
| **Maintenabilité** | la même valeur à corriger à cinq endroits, dont un qu'on oublie             |

Corollaire (principe des _12 facteurs_) : **on construit l'artefact une seule
fois, et c'est la configuration injectée au démarrage qui change.** Reconstruire
une image pour passer de staging à production, c'est ne plus déployer ce qu'on a
testé.

## 2. Les quatre niveaux disponibles

| Niveau                        | Où                                    | Pour quoi                                          |
| ----------------------------- | ------------------------------------- | -------------------------------------------------- |
| Prédéfinies GitLab            | fournies automatiquement              | `$CI_REGISTRY_IMAGE`, `$CI_COMMIT_SHORT_SHA`       |
| Globales du pipeline          | `.gitlab/ci/variables.yml`, versionné | versions d'images, réglages partagés               |
| Locales au job                | `variables:` dans le job              | ce qui ne concerne qu'un job                       |
| Projet / instance (UI GitLab) | Settings → CI/CD → Variables          | **tout ce qui est secret ou spécifique à l'infra** |

Sur le quatrième niveau, trois options à connaître :

- **Masked** : la valeur est remplacée par `[MASKED]` dans les journaux.
  Obligatoire pour `SONAR_TOKEN`, `NVD_API_KEY` et `NOTIFY_WEBHOOK_URL`.
- **Protected** : la variable n'est exposée qu'aux branches et tags protégés. À
  activer sur `PROD_NAMESPACE` : une branche `feature/*` n'a pas à connaître la
  cible de production.
- **Type File** : GitLab écrit la valeur dans un fichier temporaire et la
  variable contient _le chemin_. Le projet n'en a pas besoin : l'accès au
  cluster passe par l'agent GitLab pour Kubernetes, qui injecte lui-même
  `KUBECONFIG` dans les jobs autorisés.

## 3. Le modèle suivi

Trois motifs en place dans le dépôt, reproduits partout ailleurs.

| Sujet            | Où                                 | Pourquoi c'est bon                                                                                                |
| ---------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Découplage du CI | `.gitlab/ci/variables.yml`         | `REGISTRY_HOST: '$CI_REGISTRY'` : les scripts ignorent qu'ils tournent sur GitLab, ils restent réutilisables      |
| Réglages k6      | `tests/k6/lib/config.js`           | défaut fonctionnel + surcharge par `__ENV` + **erreur explicite si la variable est illisible**                    |
| CORS du back     | `SpringDataRestCustomization.java` | `@Value("${microcrm.cors.allowed-origins}")`, défaut local, surcharge runtime par `MICROCRM_CORS_ALLOWED_ORIGINS` |

`tests/k6/lib/config.js` est la référence : **défaut utilisable en local,
surcharge par environnement, et validation de la saisie**. Une variable mal
orthographiée y provoque une erreur immédiate au lieu d'un `NaN` silencieux qui
fausserait la mesure.

## 4. Ce qui est variabilisé

Toutes les variables globales du pipeline sont déclarées une seule fois, dans
[`.gitlab/ci/variables.yml`](.gitlab/ci/variables.yml), inclus en premier par
`.gitlab-ci.yml`.

### Images d'outillage

Toutes les images sont figées sur une version exacte, jamais `latest` ni un tag
flottant : un tag flottant fait casser une construction sans qu'aucun commit ne
l'explique, et rend deux analyses incomparables.

| Variable                                  | Valeur                                                      |
| ----------------------------------------- | ----------------------------------------------------------- |
| `NODE_IMAGE`                              | `node:22-alpine`                                            |
| `GRADLE_IMAGE`                            | `gradle:8.14.5-jdk21`                                       |
| `PYTHON_IMAGE`                            | `python:3.12-slim`                                          |
| `DOCKER_IMAGE`                            | `docker:24.0.9`                                             |
| `DOCKER_DIND_IMAGE`                       | `docker:24.0.9-dind`                                        |
| `TRIVY_IMAGE`                             | `aquasec/trivy:0.69.3`                                      |
| `GLAB_IMAGE`                              | `registry.gitlab.com/gitlab-org/cli:v1.120.0`               |
| `SHELLCHECK_IMAGE`                        | `koalaman/shellcheck-alpine:v0.11.0`                        |
| `SONAR_SCANNER_IMAGE`                     | `sonarsource/sonar-scanner-cli:11.5`                        |
| `CYPRESS_IMAGE`                           | `cypress/browsers@sha256:6a34e3c7…` (digest)                |
| `KUBECTL_IMAGE`                           | `alpine/kubectl:1.34.2`                                     |
| `HELM_IMAGE`                              | `alpine/k8s:1.36.2`                                         |
| `TERRAFORM_IMAGE`                         | `hashicorp/terraform:1.15.7`                                |
| `K6_IMAGE`                                | `grafana/k6:2.1.0`                                          |
| `POSTGRES_IMAGE`                          | `postgres:16-alpine`                                        |
| `ANSIBLE_VERSION`, `ANSIBLE_LINT_VERSION` | `14.1.0`, `26.8.0` (installés par pip dans `$PYTHON_IMAGE`) |

Trois choix méritent une note :

- **`cypress/browsers`** (image des tests du front) est figée par son digest :
  elle porte les versions de Node _et_ de Chrome, et un changement de version de
  Chrome peut à lui seul faire tomber un test.
- **`alpine/kubectl` plutôt que `bitnami/kubectl`** : `bitnami/kubectl` ne publie
  plus que `latest` sur Docker Hub, ce qui rend l'épinglage impossible.
  `alpine/kubectl` fournit les mêmes commandes avec de vraies versions ; il n'a
  pas `bash`, que `.deploy_template` installe dans son `before_script`.
- **`alpine/k8s` plutôt qu'`alpine/helm`** pour `HELM_IMAGE` : le job `lint-helm`
  compare le rendu du chart à celui des overlays Kustomize, ce qui exige
  `kubectl` en plus de `helm`. `alpine/k8s` fournit les deux, et son tag suit la
  version de kubectl. Voir [HELM.md](HELM.md) §5.

`NODE_IMAGE` et `GRADLE_IMAGE` sont alignées sur les `ARG` des Dockerfiles
(`front/Dockerfile`, `back/Dockerfile`) : le code est compilé avec la version
exacte qui a servi à le tester. Le back est compilé et exécuté en Java 21 ;
`sourceCompatibility = '17'` fixe seulement la cible du bytecode. Les versions
restent surchargeables au build via `--build-arg`.

### Identité SonarQube

| Variable                  | Consommée par                                               |
| ------------------------- | ----------------------------------------------------------- |
| `SONAR_ORGANIZATION`      | `sonar-front` (`-D`), `back/build.gradle` (`System.getenv`) |
| `SONAR_PROJECT_KEY_BACK`  | `quality-gate`, `back/build.gradle`                         |
| `SONAR_PROJECT_KEY_FRONT` | `sonar-front`, `quality-gate`                               |

Le pipeline fait autorité. `back/build.gradle` et
`front/sonar-project.properties` gardent les valeurs en **repli** uniquement,
pour qu'une analyse lancée en local vise le bon projet sans rien exporter :

```groovy
property 'sonar.projectKey', System.getenv('SONAR_PROJECT_KEY_BACK')
    ?: 'pasquietted_G-rez-le-cycle-de-vie-de-d-veloppement-logiciel'
```

### Réglages du pipeline

| Variable                          | Valeur                   | Rôle                                                          |
| --------------------------------- | ------------------------ | ------------------------------------------------------------- |
| `COVERAGE_MIN`                    | `90`                     | seuil de couverture de `coverage-gate`                        |
| `MUTATION_MIN`                    | `80`                     | seuil de mutation de `mutation-back`                          |
| `APP_BACK_NAME`, `APP_FRONT_NAME` | `back`, `front`          | noms des Deployments, des conteneurs et des images            |
| `DEPLOY_TIMEOUT`                  | `180s`                   | attente maximale d'un rollout dans `deploy.sh`, `rollback.sh` |
| `K8S_OVERLAYS_DIR`                | `k8s/overlays`           | racine des overlays Kustomize                                 |
| `HELM_CHART_DIR`                  | `helm/microcrm`          | chart Helm                                                    |
| `TERRAFORM_ENVS_DIR`              | `terraform/environments` | environnements Terraform                                      |
| `ANSIBLE_DIR`                     | `ansible`                | projet Ansible                                                |
| `REPORTS_DIR`                     | `reports`                | rapports publiés en artefacts                                 |
| `DORA_WINDOW_DAYS`                | `30`                     | fenêtre de calcul des indicateurs DORA                        |
| `KUBE_AGENT_NAME`                 | `microcrm`               | agent GitLab pour Kubernetes                                  |
| `TF_STATE_BASE_URL`               | API d'état de GitLab     | état Terraform partagé                                        |
| `DEPLOY_OVERLAY_DIR`              | `.k8s-deploy-overlay`    | overlay éphémère qui pose l'image du commit                   |
| `REGISTRY_SECRET_NAME`            | `gitlab-registry`        | Secret de tirage d'images dans le cluster                     |

### Nom du JAR

Le `back/Dockerfile` copie `build/libs/*.jar`, sans numéro de version en dur :
la tâche `jar` est désactivée dans `back/build.gradle`, si bien que Spring Boot
ne produit qu'une archive (pas de `-plain.jar` à côté). Un changement de version
ne casse donc pas la construction de l'image.

### Stack locale

`docker-compose.yml` accepte `BACK_IMAGE`, `FRONT_IMAGE`, `BACK_PORT`,
`FRONT_PORT` et `CORS_ALLOWED_ORIGINS`, tous avec un défaut inline (`${VAR:-…}`) :
`docker compose up` fonctionne donc sans configuration. Le fichier
`.env.example` documente ces réglages ; `.env` est ignoré par Git.

## 5. L'URL d'API du front (lot P1)

| Valeur                  | Emplacement               | Statut          |
| ----------------------- | ------------------------- | --------------- |
| `http://localhost:8080` | `front/src/app/config.ts` | valeur de repli |

**Le problème.** `front/Dockerfile` lance `ng build` **pendant** la construction
de l'image : une valeur lue au build est _compilée_ dans le bundle JS. La
configuration est nécessaire au build, alors que le besoin est au runtime.

| Approche                                                     | Principe                                      | Conséquence                                                                      |
| ------------------------------------------------------------ | --------------------------------------------- | -------------------------------------------------------------------------------- |
| `environments` Angular + `ARG` Docker                        | une image par environnement                   | simple, mais on perd le « build once » : l'image testée n'est pas celle déployée |
| `config.json` chargé au démarrage, ou substitution par Caddy | une seule image, config montée au déploiement | conforme aux 12 facteurs : **retenue**                                           |

**La solution.** Caddy fabrique un `/config.json` au démarrage du conteneur, à
partir de son environnement, et le bundle Angular le lit avant de démarrer
l'application :

```caddyfile
handle /config.json {
	header Content-Type application/json
	respond `{"apiBaseUrl":"{$FRONT_API_BASE_URL:http://localhost:8080}"}`
}
```

`{$VARIABLE:défaut}` est résolu par Caddy au chargement de sa configuration.
**Une seule image sert donc tous les environnements**, sans script d'entrée : le
serveur qui sert déjà le front s'en charge.

`front/src/app/config.ts` applique le motif de `tests/k6/lib/config.js` (§3) :
défaut utilisable sans configuration, surcharge par environnement, et **erreur
explicite** quand la valeur servie est illisible. Un repli silencieux sur
`localhost:8080` rendrait la panne invisible. Le détail des cas est dans
[K8S.md](K8S.md) §13.

La valeur est alimentée par `FRONT_API_BASE_URL` : depuis la ConfigMap sur
Kubernetes, depuis `docker-compose.yml` en local (avec un défaut inline qui suit
`BACK_PORT`).

`front/Caddyfile` accepte aussi `{$SITE_PORT:80}`. C'est de la souplesse, **pas**
de la sécurité : voir [K8S.md](K8S.md) §11 sur la capability de fichier du
binaire Caddy.

## 6. Ce qu'il ne faut **pas** variabiliser

- **Les noms de branches dans les `rules`** : les remplacer par des variables
  rend le pipeline illisible, et l'interpolation dans `if:` est piégeuse.
- **Les seuils k6** (`tests/k6/lib/config.js`) : ils ont déjà des défauts
  surchargeables par environnement. Les exposer en variables de projet
  permettrait de les desserrer depuis l'interface pour faire passer un pipeline
  rouge.
- **`checkstyle.ignoreFailures = false`** : décision de politique, pas de
  contexte.
- **Les identifiants de `docker-compose.sonar.yml`** et de la base PostgreSQL des
  jobs de test : outillage jamais déployé ; les externaliser donnerait une
  fausse impression de sécurité.

## 7. Variables GitLab à créer dans l'interface

Seules celles-ci restent hors du dépôt. Tout le reste vit dans
`.gitlab/ci/variables.yml`, versionné et relisible en revue.

| Variable             | Type             | Protected | Rôle                                   |
| -------------------- | ---------------- | --------- | -------------------------------------- |
| `SONAR_HOST_URL`     | Variable         | non       | URL du serveur SonarQube ou SonarCloud |
| `SONAR_TOKEN`        | Variable, masked | non       | Token d'analyse                        |
| `NVD_API_KEY`        | Variable, masked | non       | Accélère Dependency-Check              |
| `STAGING_NAMESPACE`  | Variable         | non       | Namespace de staging                   |
| `PROD_NAMESPACE`     | Variable         | **oui**   | Namespace de production                |
| `NOTIFY_WEBHOOK_URL` | Variable, masked | non       | Canal d'équipe (facultative)           |
| `CI_REGISTRY*`       | automatique      | —         | Fournies par GitLab                    |
| `FRONT_API_BASE_URL` | _facultative_    | non       | Voir la nuance ci-dessous              |

Aucun kubeconfig n'est stocké : l'agent GitLab pour Kubernetes fournit l'accès
au cluster. Le déploiement n'ajoute **aucune autre variable obligatoire**. Les
manifestes Kustomize reçoivent le namespace en argument
(`kubectl apply -k … -n "$STAGING_NAMESPACE"`), l'image par l'overlay éphémère
que compose le job, et les identifiants du registry viennent des
`$CI_REGISTRY*` que GitLab fournit. Inscrire un `namespace:` dans un overlay
remettrait dans le dépôt une coordonnée d'infrastructure, et créerait une
seconde source de vérité.

### Le cas `FRONT_API_BASE_URL`

**Sa source de vérité est la ConfigMap des overlays**
(`k8s/overlays/<env>/configmap-patch.yaml`), pas l'interface GitLab. Le critère
de §1 le justifie : ce n'est pas un secret, et c'est une valeur qui décrit un
environnement. Rangée à côté des hôtes d'Ingress du même overlay, elle est
relisible en revue et cohérente par construction : l'URL d'API et l'hôte qui la
sert sont dans le même fichier et ne peuvent pas diverger.

C'est néanmoins la seule valeur du projet qui **demanderait un scope par
environnement** (champ « Environment scope » de GitLab) si l'équipe préférait la
piloter depuis l'interface sans commit, puisque sa valeur diffère entre staging
et production. D'où sa présence en _facultative_ dans le tableau.
