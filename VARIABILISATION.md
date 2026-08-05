# Variabilisation de la CI/CD

Inventaire des valeurs codées en dur dans le dépôt, de celles qui sont déjà
externalisées, et du plan pour traiter le reste.

**État : lots P2 et P3 traités. Reste le lot P1 (URL d'API du front).**

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
| Globales du pipeline          | bloc `variables:` du `.gitlab-ci.yml` | versions d'images, réglages partagés               |
| Locales au job                | `variables:` dans le job              | ce qui ne concerne qu'un job                       |
| Projet / instance (UI GitLab) | Settings → CI/CD → Variables          | **tout ce qui est secret ou spécifique à l'infra** |

Sur le quatrième niveau, trois options à connaître :

- **Masked** — la valeur est remplacée par `[MASKED]` dans les logs. Obligatoire
  pour `SONAR_TOKEN` et `NVD_API_KEY`.
- **Protected** — la variable n'est exposée qu'aux branches et tags protégés.
  À activer sur `KUBE_CONFIG` et `PROD_NAMESPACE` : sans ça, n'importe quelle
  branche `feature/*` peut lire les accès de production.
- **Type File** — GitLab écrit la valeur dans un fichier temporaire et la
  variable contient _le chemin_. C'est pour cette raison que
  `KUBECONFIG: '$KUBE_CONFIG'` fonctionne : `kubectl` attend un chemin, pas un
  contenu YAML.

## 3. Le modèle à suivre

Trois motifs déjà en place dans le dépôt, à reproduire ailleurs.

| Sujet            | Où                                  | Pourquoi c'est bon                                                                                                |
| ---------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Découplage du CI | `.gitlab-ci.yml` (bloc `variables`) | `REGISTRY_HOST: '$CI_REGISTRY'` — les scripts ignorent qu'ils tournent sur GitLab, ils restent réutilisables      |
| Réglages k6      | `tests/k6/lib/config.js`            | défaut fonctionnel + surcharge par `__ENV` + **erreur explicite si la variable est illisible**                    |
| CORS du back     | `SpringDataRestCustomization.java`  | `@Value("${microcrm.cors.allowed-origins}")`, défaut local, surcharge runtime par `MICROCRM_CORS_ALLOWED_ORIGINS` |

`tests/k6/lib/config.js` est la référence : **défaut utilisable en local,
surcharge par environnement, et validation de la saisie**. Une variable mal
orthographiée y provoque une erreur immédiate au lieu d'un `NaN` silencieux qui
fausserait la mesure.

## 4. Ce qui a été variabilisé

### Images d'outillage — `.gitlab-ci.yml`

Neuf images étaient flottantes ou répétées ; toutes sont désormais figées et
déclarées une seule fois.

| Variable              | Valeur                                      | Avant                      |
| --------------------- | ------------------------------------------- | -------------------------- |
| `NODE_IMAGE`          | `node:22-alpine`                            | `node` — **aucun tag**, ×2 |
| `GRADLE_IMAGE`        | `gradle:8.14.5-jdk21`                       | `gradle:jdk21` ×6          |
| `PYTHON_IMAGE`        | `python:3.12-slim`                          | ×3                         |
| `DOCKER_IMAGE`        | `docker:24.0.9`                             | `docker:24`                |
| `DOCKER_DIND_IMAGE`   | `docker:24.0.9-dind`                        | `docker:24-dind`           |
| `TRIVY_IMAGE`         | `aquasec/trivy:0.69.3`                      | `latest` ×3                |
| `SHELLCHECK_IMAGE`    | `koalaman/shellcheck-alpine:v0.11.0`        | tag flottant `stable`      |
| `SONAR_SCANNER_IMAGE` | `sonarsource/sonar-scanner-cli:11.5`        | `latest`                   |
| `CYPRESS_IMAGE`       | `cypress/browsers:node-22.21.0-chrome-141…` | `latest`                   |
| `KUBECTL_IMAGE`       | `alpine/kubectl:1.34.2`                     | `bitnami/kubectl:latest`   |
| `K6_IMAGE`            | `grafana/k6:2.1.0`                          | déjà figée                 |

Deux choix méritent une note :

- **`cypress/browsers`** — le tag porte les versions de Node _et_ des
  navigateurs. C'est verbeux, mais c'est exactement ce qu'on veut figer : un
  changement de version de Chrome peut à lui seul faire tomber un test.
- **`bitnami/kubectl` → `alpine/kubectl`** — depuis la reprise du catalogue
  Bitnami (2025), `bitnami/kubectl` ne publie plus que `latest` sur Docker Hub :
  l'épingler est devenu impossible. `alpine/kubectl` fournit les mêmes commandes
  avec de vraies versions. Conséquence : l'image est basée sur Alpine et n'a pas
  `bash`, que `.deploy_template` installe donc dans son `before_script`, comme le
  fait déjà `.package_template`.

`NODE_IMAGE` et `GRADLE_IMAGE` sont alignées sur les Dockerfiles : le code est
compilé avec la version qui a servi à le tester.

### Identité SonarQube

Trois valeurs qui vivaient à six endroits :

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

| Variable         | Valeur  | Remplace                                                |
| ---------------- | ------- | ------------------------------------------------------- |
| `COVERAGE_MIN`   | `70`    | `--min 70` en dur dans `coverage-gate`                  |
| `APP_BACK_NAME`  | `back`  | 9 occurrences (deployments, conteneurs, images)         |
| `APP_FRONT_NAME` | `front` | 8 occurrences                                           |
| `DEPLOY_TIMEOUT` | `180s`  | valeur par défaut des scripts, jamais pilotée par la CI |

### Nom du JAR

Les deux étapes du `back/Dockerfile` utilisent maintenant des `ARG`
(`GRADLE_IMAGE`, `RUNTIME_IMAGE`), tags épinglés.

Le `COPY` référençait `microcrm-0.0.1-SNAPSHOT.jar`, donc cassait au premier
changement de version. Un motif `*.jar` était impossible tant que Spring Boot
produisait deux archives (le jar exécutable et un `-plain.jar`). La tâche `jar`
est donc désactivée dans `back/build.gradle` — une seule archive, `COPY
build/libs/*.jar`, plus aucun numéro de version en dur.

### Deux correctifs, commités séparément

Ce sont des corrections de comportement et non de la variabilisation, d'où un
commit distinct.

1. **Trois JDK pour un même artefact.** Le back se construisait en
   `gradle:jdk17`, s'exécutait sur un JRE 21 et était testé en CI sur
   `gradle:jdk21` : l'image livrée n'était pas produite par la chaîne qui la
   valide. `GRADLE_IMAGE` vaut désormais `gradle:8.14.5-jdk21` dans le
   Dockerfile comme dans le pipeline. `sourceCompatibility = '17'` est
   inchangé, et le bytecode produit reste en version majeure 61 (Java 17) :
   c'est le compilateur qui change, pas la cible.
2. **`EXPOSE 4200` dans `back/Dockerfile`** alors que l'application écoute sur
   `8080`. Corrigé, et le commentaire du job `perf-k6` qui documentait
   l'incohérence est mis à jour.

### Stack locale

`docker-compose.yml` accepte `BACK_IMAGE`, `FRONT_IMAGE`, `BACK_PORT`,
`FRONT_PORT` et `CORS_ALLOWED_ORIGINS`, tous avec un défaut inline (`${VAR:-…}`)
— la commande `docker compose up` fonctionne donc sans configuration. Le fichier
`.env.example` documente ces réglages ; `.env` est ignoré par Git.

## 5. Ce qui reste — P1 : l'URL d'API du front

| Valeur                  | Emplacement               |
| ----------------------- | ------------------------- |
| `http://localhost:8080` | `front/src/app/config.ts` |

C'est le point bloquant pour un vrai déploiement. `front/Dockerfile` lance
`ng build` **pendant** la construction de l'image : la valeur est _compilée_
dans le bundle JS. L'image poussée par `package-front` puis déployée par
`deploy-production` contient en dur `localhost:8080` — en production, le
navigateur appellera la machine de l'utilisateur, pas l'API.

C'est le piège classique du front : la configuration est nécessaire au _build_,
alors que le besoin est au _runtime_. Deux sorties :

| Approche                                                     | Principe                                      | Conséquence                                                                      |
| ------------------------------------------------------------ | --------------------------------------------- | -------------------------------------------------------------------------------- |
| `environments` Angular + `ARG` Docker                        | une image par environnement                   | simple, mais on perd le « build once » : l'image testée n'est pas celle déployée |
| `config.json` chargé au démarrage, ou substitution par Caddy | une seule image, config montée au déploiement | conforme aux 12 facteurs — **recommandé**                                        |

Note connexe : `front/Caddyfile` sert l'application en `:80` en dur.

## 6. Ce qu'il ne faut **pas** variabiliser

- **Les noms de branches dans les `rules`** — les remplacer par des variables
  rend le pipeline illisible et l'interpolation dans `if:` est piégeuse.
- **Les seuils k6** (`tests/k6/lib/config.js`) — ils ont déjà des défauts
  surchargeables par environnement, ce qui suffit. Les exposer en variables de
  projet permettrait de les desserrer depuis l'interface pour faire passer un
  pipeline rouge : le garde-fou perdrait son sens.
- **`checkstyle.ignoreFailures = false`** — décision de politique, pas de contexte.
- **Les identifiants de `docker-compose.sonar.yml`** — outillage local jamais
  déployé ; les externaliser donnerait une fausse impression de sécurité.

## 7. Variables GitLab à créer dans l'interface

Seules celles-ci doivent rester hors du dépôt. Tout le reste vit dans le bloc
`variables:` du `.gitlab-ci.yml`, où c'est versionné et relisible en revue.

| Variable            | Type             | Protected | Rôle                      |
| ------------------- | ---------------- | --------- | ------------------------- |
| `SONAR_HOST_URL`    | Variable         | non       | URL du serveur SonarQube  |
| `SONAR_TOKEN`       | Variable, masked | non       | Token d'analyse           |
| `NVD_API_KEY`       | Variable, masked | non       | Accélère Dependency-Check |
| `KUBE_CONFIG`       | **File**         | **oui**   | Connexion au cluster      |
| `STAGING_NAMESPACE` | Variable         | non       | Namespace de staging      |
| `PROD_NAMESPACE`    | Variable         | **oui**   | Namespace de production   |
| `CI_REGISTRY*`      | automatique      | —         | Fournies par GitLab       |

Quand le lot P1 sera traité, `FRONT_API_BASE_URL` s'y ajoutera — c'est la seule
variable qui devra être _scopée par environnement_ (champ « Environment scope »),
sa valeur différant entre staging et production.
