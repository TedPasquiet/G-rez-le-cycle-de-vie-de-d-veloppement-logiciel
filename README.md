<p align="center">
   <img src="./front/src/favicon.png" width="192px" alt="Logo de MicroCRM" />
</p>

# MicroCRM (P5 - Expert DevOps - Gérez le cycle de vie de développement logiciel)

MicroCRM est une application de démonstration basique ayant pour objectif de servir de socle pour le module "P5 - Expert DevOps".

L'application MicroCRM est une implémentation simplifiée d'un ["CRM" (Customer Relationship Management)](https://fr.wikipedia.org/wiki/Gestion_de_la_relation_client). Les fonctionnalités sont limitées à la création, édition et la visualisations des individus liés à des organisations.

![Page d'accueil](./misc/screenshots/screenshot_1.png)
![Édition de la fiche d'un individu](./misc/screenshots/screenshot_2.png)

## La chaîne CI/CD, étape par étape

Le pipeline compte **39 jobs répartis en 10 étapes**, définis dans
[`.gitlab-ci.yml`](./.gitlab-ci.yml) et **13 fichiers** de `.gitlab/ci/`, un par
domaine. Chaque étape ne laisse passer que ce qu'elle a vérifié.

| Étape         | Ce qu'elle fait                                                                                                   | Bloquante          | Détail                                                     |
| ------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------ | ---------------------------------------------------------- |
| `lint`        | Mise en forme, ShellCheck, manifestes k8s, chart Helm, concordance des versions                                   | oui                | [QUALITY.md](./QUALITY.md)                                 |
| `test`        | Suites back (JUnit), front (Karma) et celle des scripts du dépôt                                                  | oui                | [QUALITY.md](./QUALITY.md) §7                              |
| `quality`     | SonarQube, SpotBugs, seuil de couverture, force des assertions (PIT)                                              | oui, sauf SpotBugs | [QUALITY.md](./QUALITY.md) §1-2                            |
| `security`    | CVE des dépendances, secrets et misconfigurations du dépôt                                                        | oui                | [QUALITY.md](./QUALITY.md) §3-4                            |
| `infra`       | `terraform validate`, `terraform plan`, `ansible-lint`                                                            | oui                | [TERRAFORM.md](./TERRAFORM.md), [ANSIBLE.md](./ANSIBLE.md) |
| `build`       | Artefacts back (jar) et front (bundle)                                                                            | oui                | —                                                          |
| `package`     | Images Docker taguées par SHA, scannées **avant** d'être poussées ; promotion SemVer et Release GitLab sur un tag | oui                | [ARCHITECTURE.md](./ARCHITECTURE.md) §4                    |
| `perf`        | k6 contre l'image qui vient d'être construite                                                                     | fumée seulement    | [QUALITY.md](./QUALITY.md) §5                              |
| `deploy`      | Déploiement staging et production, retour arrière, collecte des indicateurs DORA                                  | manuel             | [RELEASE.md](./RELEASE.md)                                 |
| `infra-apply` | `terraform apply` par environnement, notification d'échec                                                         | manuel             | [TERRAFORM.md](./TERRAFORM.md) §4                          |

Le raisonnement derrière ce découpage — pourquoi `infra` avant `build`, pourquoi
`infra-apply` en dernier, pourquoi la performance est un pipeline enfant — est
dans [docs/pipeline-ci.md](./docs/pipeline-ci.md).

**Les outils**, toutes versions figées dans
[`.gitlab/ci/variables.yml`](./.gitlab/ci/variables.yml) ; leur choix est
justifié dans [VEILLE.md](./VEILLE.md).

| Domaine               | Outils                                                                 |
| --------------------- | ---------------------------------------------------------------------- |
| Intégration continue  | GitHub (dépôt principal), miroir GitLab CI, runner Docker auto-hébergé |
| Tests                 | JUnit et JaCoCo (back), Karma (front), PIT (mutation), k6              |
| Qualité               | ESLint, Checkstyle, ShellCheck, SonarCloud, SpotBugs                   |
| Sécurité              | OWASP Dependency-Check, Trivy (dépôt et images)                        |
| Conteneurs et cluster | Docker, Kubernetes (minikube), Kustomize, Helm, agent GitLab           |
| Infrastructure        | Terraform (état hébergé par GitLab), Ansible                           |
| Supervision           | Elasticsearch, Kibana, Filebeat, OpenTelemetry et Elastic APM          |

**Configuration, tests et déploiement du pipeline** :
[VARIABILISATION.md](./VARIABILISATION.md) pour les valeurs externalisées,
[QUALITY.md](./QUALITY.md) pour la liste des variables CI/CD à créer dans
GitLab, [K8S.md](./K8S.md) et [HELM.md](./HELM.md) pour les manifestes. Les
procédures de déploiement sont dans la section suivante.

## Déployer

Tout ce qu'il faut pour déployer, publier une version, revenir en arrière et
reconstruire un environnement, sans ouvrir un autre fichier. Les renvois en fin
de paragraphe mènent au détail et aux raisons.

**Le principe, en trois lignes.** Une image est construite **une fois**, taguée
par le SHA court du commit, scannée, puis poussée au registry GitLab. Le
déploiement ne reconstruit rien : il pose cette image dans un namespace. La
décision de déployer est le seul geste manuel — un clic sur un job.

| Environnement | Namespace             | Branche          | Job                 |
| ------------- | --------------------- | ---------------- | ------------------- |
| staging       | `microcrm-staging`    | `develop`        | `deploy-staging`    |
| production    | `microcrm-production` | `main` ou un tag | `deploy-production` |

### 1. Prérequis, à poser une seule fois

**a. Un runner.** Les jobs `package-*` construisent des images avec Docker in
Docker : il faut un runner à exécuteur `docker` en mode **privilégié**. Celui du
projet est auto-hébergé sur le poste — `gitlab-runner` 19.1.1,
`executor = "docker"`, `privileged = true`, relu dans sa configuration le
2026-10-02.

```shell
gitlab-runner register --url https://gitlab.com --token <jeton du runner> \
  --executor docker --docker-image alpine:3.24 --docker-privileged
gitlab-runner run
```

**b. L'agent GitLab pour Kubernetes.** Les jobs joignent le cluster par le
tunnel de l'agent `microcrm`, pas par un kubeconfig stocké en variable.

```shell
# 1. .gitlab/agents/microcrm/config.yaml doit être sur la branche par défaut
#    (main) : GitLab ne le lit nulle part ailleurs.
# 2. Les droits de l'agent dans le cluster
kubectl apply -f .gitlab/agents/microcrm/rbac.yaml
# 3. GitLab > Operate > Kubernetes clusters > Connect a cluster > microcrm
#    affiche un jeton ; l'installer dans le cluster :
helm upgrade --install microcrm gitlab/gitlab-agent \
  --namespace gitlab-agent-microcrm --create-namespace \
  --set config.token=<jeton affiché par GitLab> \
  --set config.kasAddress=grpcs://kas.gitlab.com \
  --set rbac.useExistingRole=gitlab-agent-microcrm
# 4. L'agent doit apparaître « connected » dans la même page.
```

**c. Les variables CI/CD**, dans GitLab > Settings > CI/CD > Variables. Tout le
reste vit dans `.gitlab/ci/variables.yml`, versionné.

| Variable             | Type             | Obligatoire       | Valeur                                           |
| -------------------- | ---------------- | ----------------- | ------------------------------------------------ |
| `STAGING_NAMESPACE`  | Variable         | **oui**           | `microcrm-staging`                               |
| `PROD_NAMESPACE`     | Variable         | **oui**           | `microcrm-production`                            |
| `SONAR_HOST_URL`     | Variable         | oui (étape Sonar) | URL du serveur SonarQube ou SonarCloud           |
| `SONAR_TOKEN`        | Variable, masked | oui (étape Sonar) | Jeton d'analyse                                  |
| `NVD_API_KEY`        | Variable, masked | non               | Accélère Dependency-Check                        |
| `NOTIFY_WEBHOOK_URL` | Variable, masked | non               | Canal d'équipe pour les notifications            |
| `CI_REGISTRY*`       | automatiques     | —                 | Fournies par GitLab : accès au registry d'images |

Les deux namespaces doivent valoir **exactement** le nom que Terraform crée
(`terraform/environments/<env>/terraform.tfvars`, clé `namespace`) : rien ne
compare les deux. Une variable vide fait échouer le job (`exige_namespace`) au
lieu de déployer dans `default`. Côté GitHub, le secret `GITLAB_TOKEN` (portée
`write_repository`) alimente le miroir vers GitLab.

**d. Les namespaces**, créés par Terraform avec leur quota, leurs limites et
leurs policies : jobs manuels `terraform-apply-staging`,
`terraform-apply-production` et `terraform-apply-logging` (pipeline de `main`,
étape `infra-apply`), ou depuis un poste — voir le point 6.

Détail : [TERRAFORM.md](./TERRAFORM.md) §4.1 (agent), [QUALITY.md](./QUALITY.md)
(variables), [K8S.md](./K8S.md) §10 et §12 (cluster vierge, accès au registry).

### 2. Déployer en staging

1. Fusionner la Pull Request dans `develop`. Le pipeline du miroir GitLab
   construit les deux images (`package-back`, `package-front`), les scanne
   **avant** de les pousser — une image qui porte une CVE haute ou critique
   n'atteint pas le registry — puis les publie sous le SHA court du commit. Les
   rapports Trivy sont dans les artefacts du job (`reports/trivy-image-*.json`
   et `.txt`).
2. Dans GitLab > Build > Pipelines, ouvrir le pipeline de `develop` et lancer le
   job **`deploy-staging`** (étape `deploy`, manuel).

Le job fait quatre choses, dans cet ordre : il recrée le `Secret`
`gitlab-registry` qui ouvre le registry au cluster ; il compose un overlay
Kustomize éphémère qui pose l'image du commit sur `k8s/overlays/staging` ; il
l'applique (`kubectl apply -k`) ; puis `scripts/deploy/deploy.sh` attend la fin
du rollout (180 s, `DEPLOY_TIMEOUT`) et **revient de lui-même à la version
précédente** s'il n'aboutit pas. Le résultat est annoncé sur le canal d'équipe
si `NOTIFY_WEBHOOK_URL` est définie.

Dans la même étape, le job `dora-metrics` tourne seul, sans clic : il calcule
les quatre indicateurs DORA depuis l'historique des pipelines et les publie en
artefact (`reports/dora.json`). Il ne déploie rien et ne bloque rien.

### 3. Déployer en production

1. Fusionner `develop` dans `main` par Pull Request, pipeline vert.
2. Dans le pipeline de `main`, lancer le job **`deploy-production`** (manuel —
   c'est le garde-fou voulu). Même séquence qu'en staging, sur l'overlay
   `production` et le namespace `$PROD_NAMESPACE`. L'image déployée est celle
   du commit de `main`, taguée par son SHA.

Pour qu'une mise en production porte un **numéro de version**, passer par le
point 4 : le déploiement se lance alors depuis le pipeline du tag.

### 4. Publier une version

La règle : **le tag se pose sur un commit de `main` dont le pipeline a déjà
construit, scanné et poussé les deux images.**

```shell
# 1. Sur develop, AVANT la fusion : les trois fichiers de version portent X.Y.Z
#    (front/package.json, back/build.gradle, appVersion de helm/microcrm/Chart.yaml).
bash scripts/ci/check_version.sh --version vX.Y.Z   # le contrôle que joue la CI

# 2. Fusionner develop dans main, puis attendre que le pipeline de main ait
#    passé package-back et package-front : c'est lui qui construit les images.

# 3. Poser le tag SemVer sur ce commit de main, et le pousser.
git checkout main && git pull origin main
git tag -a vX.Y.Z -m "MicroCRM X.Y.Z"
git push origin vX.Y.Z
```

Le pipeline du tag **ne reconstruit rien** : `version-consistency` vérifie la
concordance des versions, puis `promote-back` et `promote-front` ajoutent le
tag `X.Y.Z` (sans le « v ») à l'image déjà publiée pour ce commit — même
digest, donc exactement l'artefact scanné et testé — et le job `release` crée
la Release GitLab. Lancer ensuite **`deploy-production`** dans ce pipeline : il
déploie `back:X.Y.Z` et `front:X.Y.Z`. Si l'image du commit n'existe pas, la
promotion échoue, et c'est voulu : on ne reconstruit pas, on repose le tag au
bon endroit.

Preuve : release 1.0.1 jouée le 5 octobre 2026 (pipelines #2909284076,
#2912362926, #2913490784) ; `back:1.0.1` et `back:08a216b0` ont le même digest,
la Release GitLab `v1.0.1` est créée par le job `release`, la production tourne
en `1.0.1` ([RELEASE.md](./RELEASE.md) §7.5).

Détail, et que faire quand la promotion échoue : [RELEASE.md](./RELEASE.md)
§2.1, §2.2 et §7.

### 5. Revenir en arrière

| Situation                                          | Geste                                                          |
| -------------------------------------------------- | -------------------------------------------------------------- |
| Le rollout n'aboutit pas pendant un déploiement    | **Aucun** : `deploy.sh` a déjà rétabli la révision précédente  |
| Un défaut apparaît après un déploiement réussi     | Job **`rollback-production`** (pipeline de `main` ou d'un tag) |
| Même chose en staging, ou hors CI, depuis un poste | `scripts/deploy/rollback.sh`, ci-dessous                       |

```shell
export KUBECONFIG=~/.kube/config   # le script l'exige ; en CI, l'agent le fournit

# Revenir à la révision précédente (back puis front)
bash scripts/deploy/rollback.sh -n microcrm-production -d back
bash scripts/deploy/rollback.sh -n microcrm-production -d front

# Choisir une révision précise
kubectl -n microcrm-production rollout history deployment/back
bash scripts/deploy/rollback.sh -n microcrm-production -d back --to-revision 7
```

Codes de sortie : `0` rétabli, `1` erreur de configuration, `3` le rollback
lui-même a échoué. Deux pièges :

- **Ne pas enchaîner un rollback manuel après un rollback automatique** : la
  version saine est déjà revenue, « la précédente » est redevenue la mauvaise.
- **Un rollback ramène l'image, pas la ConfigMap.** Revenir à une image
  qui ne contient pas l'agent OpenTelemetry alors que la ConfigMap porte `JAVA_TOOL_OPTIONS=-javaagent:…` donne un pod qui ne
  démarre pas : retirer d'abord cette clé ([MONITORING.md](./MONITORING.md)
  §10.5).

Détail : [RELEASE.md](./RELEASE.md) §5, [K8S.md](./K8S.md) §14.6 et §14.10.

### 6. Reconstruire un environnement depuis un poste nu

Trois outils, dans cet ordre, parce que chacun possède une couche et une seule :
Ansible le poste et le cluster, Terraform le namespace et ses garde-fous,
Kustomize l'application.

```shell
# 1. L'outillage et le cluster minikube (addons ingress et registry)
cd ansible && ansible-playbook site.yml && cd ..

# 2. Le namespace, son quota, ses limites, ses policies. L'état Terraform est
#    partagé, hébergé par GitLab : il faut ses coordonnées.
export TF_STATE_BASE_URL='https://gitlab.com/api/v4/projects/<id>/terraform/state'
export TF_HTTP_USERNAME='<identifiant GitLab>'
export TF_HTTP_PASSWORD='<jeton personnel, portée api>'
scripts/ci/terraform_check.sh --apply -e staging

# 3. Les images. Sans accès au registry : les construire et les charger.
TAG="local-$(git rev-parse --short HEAD)"
docker build -t "microcrm/back:$TAG" ./back
docker build -t "microcrm/front:$TAG" ./front
minikube image load "microcrm/back:$TAG"
minikube image load "microcrm/front:$TAG"

# 4. L'application, par un overlay éphémère qui pose la vraie image — celui que
#    la CI fabrique. Le répertoire doit être DANS le dépôt (chemin relatif).
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
kubectl -n microcrm-staging rollout status deployment/back  --timeout=300s
kubectl -n microcrm-staging rollout status deployment/front --timeout=300s
```

Ne pas appliquer `k8s/overlays/staging` tel quel : ses manifestes portent
volontairement `microcrm/back:PLACEHOLDER`, et le pod resterait en
`ImagePullBackOff`. Pour la production, remplacer `staging` par `production`
aux étapes 2 et 4. Pour la supervision :
`scripts/ci/terraform_check.sh --apply -e logging`, puis
`kubectl apply -k k8s/elk -n logging`.

Preuve : procédure jouée de bout en bout le 22 septembre 2026, à partir d'un
namespace détruit ([RELEASE.md](./RELEASE.md) §9.4-9.5). Détail : [ANSIBLE.md](./ANSIBLE.md), [TERRAFORM.md](./TERRAFORM.md)
§10, [K8S.md](./K8S.md) §14.9.

### 7. Vérifier

```shell
NS=microcrm-staging            # ou microcrm-production

# Ce qui tourne, et sous quelle image
kubectl -n "$NS" get deployments -o wide
kubectl -n "$NS" get pods,svc,ingress

# L'historique des révisions, vers lequel un rollback peut revenir
kubectl -n "$NS" rollout history deployment/back

# L'API répond, et les données de démonstration sont là
kubectl -n "$NS" port-forward svc/back 18081:8080 &
curl -s http://127.0.0.1:18081/actuator/health   # {"status":"UP",…}
curl -s http://127.0.0.1:18081/persons | head -c 200

# Le routage par hôte, à travers le contrôleur d'Ingress
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 18080:80 &
curl -s -H 'Host: api.microcrm.staging.example.com' http://127.0.0.1:18080/persons | head -c 200
curl -s -H 'Host: microcrm.staging.example.com'     http://127.0.0.1:18080/config.json
```

Sans rien déployer, les deux suites du dépôt contrôlent les scripts et les
manifestes : `bash scripts/tests/run_tests.sh` et
`bash scripts/tests/validate_k8s.sh`. Les logs de ce qui tourne, et les alertes
levées par les huit règles de `k8s/elk/alerting/`, se lisent dans Kibana
([MONITORING.md](./MONITORING.md) §11 pour installer les règles) — et seulement
là : aucune alerte ne sort de Kibana.

## Les scripts d'automatisation

Toute la logique du pipeline vit dans `scripts/`, jamais dans des blocs YAML :
un script est testable en local, relu par ShellCheck, et doublé de faux binaires
qui permettent d'éprouver ses chemins d'échec. **Le but, le fonctionnement et
les paramètres de chacun sont documentés dans [SCRIPTS.md](./SCRIPTS.md).**

| Script                              | Ce qu'il fait                                                         |
| ----------------------------------- | --------------------------------------------------------------------- |
| `lib/common.sh`                     | Fonctions communes : journalisation, vérifications, `retry`           |
| `ci/build_and_push.sh`              | Construit une image Docker et l'envoie au registry                    |
| `ci/promote_image.sh`               | Pose le numéro de version SemVer sur une image déjà construite        |
| `ci/trivy_scan.sh`                  | Lance un scan Trivy et en garde un rapport JSON et un tableau lisible |
| `ci/release_notes.sh`               | Écrit la description de la Release GitLab d'une version               |
| `ci/collect_security.py`            | Transforme les rapports des scanners en documents Elasticsearch       |
| `ci/check_version.sh`               | Vérifie que les versions du dépôt suivent le tag de release           |
| `ci/terraform_check.sh`             | `fmt`, `validate`, `plan` et `apply` par environnement                |
| `ci/ansible_check.sh`               | Contrôle les playbooks et les rôles                                   |
| `ci/quality_gate.py`                | Vérifie le Quality Gate SonarCloud                                    |
| `ci/check_coverage.py`              | Vérifie le taux de couverture des tests du back                       |
| `ci/collect_dora.py`                | Calcule les quatre indicateurs DORA depuis l'API GitLab               |
| `ci/notify.py`                      | Annonce le résultat d'une étape sur un canal d'équipe                 |
| `monitoring/install_alerting.py`    | Installe les huit règles d'alerte Kibana, et la clé de chiffrement    |
| `deploy/deploy.sh`                  | Déploie sur Kubernetes, avec retour arrière automatique               |
| `deploy/rollback.sh`                | Revient à la révision précédente                                      |
| `tests/run_tests.sh`                | **430 assertions** sur tous les scripts ci-dessus                     |
| `tests/validate_k8s.sh`             | **151 assertions** sur les manifestes et le chart, sans cluster       |
| `tests/run_k6.sh`                   | Lance les scénarios de performance                                    |
| `tests/check_accessibilite_docs.py` | Contrôle l'accessibilité des documents livrables                      |
| `docs/build_pdf.sh`                 | Produit les PDF balisés des livrables, et vérifie leur balisage       |

```bash
bash scripts/tests/run_tests.sh      # teste les scripts, sans cluster ni registry
bash scripts/tests/validate_k8s.sh   # valide k8s/ et helm/, sans cluster
```

## Toute la documentation

| Document                                                                 | Ce qu'on y trouve                                                                                                                  |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| [AUDIT.md](./AUDIT.md)                                                   | Audit du processus initial, SWOT, et le **plan de sécurité** (risques, objectifs, contrôles, traitement des vulnérabilités)        |
| [VEILLE.md](./VEILLE.md)                                                 | Veille technologique et justification de chaque outil retenu                                                                       |
| [QUALITY.md](./QUALITY.md)                                               | **Plan de tests et de sécurité** : Sonar, SpotBugs, Dependency-Check, Trivy, k6, supervision, couverture                           |
| [ARCHITECTURE.md](./ARCHITECTURE.md)                                     | Architecture de l'application et de la plateforme, **schémas IaC**                                                                 |
| [RELEASE.md](./RELEASE.md)                                               | **Plan d'automatisation des releases** : versionnage SemVer, déploiement, rollback, sauvegarde et restauration                     |
| [K8S.md](./K8S.md)                                                       | Manifestes Kubernetes, overlays Kustomize, preuves de déploiement                                                                  |
| [HELM.md](./HELM.md)                                                     | Le chart, et pourquoi il vient en plus de Kustomize                                                                                |
| [TERRAFORM.md](./TERRAFORM.md)                                           | Namespaces, quotas, policies, état partagé                                                                                         |
| [ANSIBLE.md](./ANSIBLE.md)                                               | Provisionnement du poste et du cluster                                                                                             |
| [MONITORING.md](./MONITORING.md)                                         | Stack ELK, cinq tableaux de bord, **indicateurs DORA**, **traces OpenTelemetry et Elastic APM**, **alerting** (huit règles Kibana) |
| [SCRIPTS.md](./SCRIPTS.md)                                               | Chaque script : son but, son fonctionnement, ses paramètres                                                                        |
| [VARIABILISATION.md](./VARIABILISATION.md)                               | Ce qui est externalisé, et pourquoi                                                                                                |
| [GUIDE.md](./GUIDE.md)                                                   | Prise en main rapide du dépôt                                                                                                      |
| [docs/pipeline-ci.md](./docs/pipeline-ci.md)                             | Le découpage du pipeline et les pièges de `include:`/`extends:`                                                                    |
| [docs/plan-optimisation-release.md](./docs/plan-optimisation-release.md) | Plan d'optimisation du cycle de release, par vagues                                                                                |

**Livrables PDF** : [rapport de performance](./docs/rapport-performance.pdf) et
[documentation d'infrastructure](./docs/documentation-infrastructure.pdf). Les
captures qui les accompagnent sont dans [`docs/captures/`](./docs/captures/).

## Code source

### Organisation

Ce [monorepo](https://en.wikipedia.org/wiki/Monorepo) contient les 2 composantes du projet "MicroCRM":

- La partie serveur (ou "backend"), en Java SpringBoot 3;
- La partie cliente (ou "frontend"), en Angular 20.

Le pipeline GitLab CI est défini par [`.gitlab-ci.yml`](./.gitlab-ci.yml) et
les fichiers de `.gitlab/ci/` (voir plus haut). La configuration du pipeline et les valeurs à externaliser sont détaillées dans
[VARIABILISATION.md](./VARIABILISATION.md).

### Démarrer avec les sources

#### Serveur

##### Dépendances

- [OpenJDK >= 17](https://openjdk.org/)

##### Procédure

1. Se positionner dans le répertoire `back` avec une invite de commande:

   ```shell
   cd back
   ```

2. Construire le JAR:

   ```shell
   # Sur Linux
   ./gradlew build

   # Sur Windows
   gradlew.bat build
   ```

3. Démarrer le service:

   ```shell
   java -jar build/libs/microcrm-*.jar
   ```

Puis ouvrir l'URL http://localhost:8080 dans votre navigateur.

#### Client

##### Dépendances

- [NPM >= 10.2.4](https://www.npmjs.com/)
- Node.js `^20.19`, `^22.12` ou `>=24` — contrainte d'Angular 20

##### Procédure

1. Se positionner dans le répertoire `front` avec une invite de commande:

   ```shell
   cd front
   ```

2. (La première fois seulement) Installer les dépendances NodeJS:

   ```shell
   npm install
   ```

3. Démarrer le service de développement:

   ```shell
   npx @angular/cli serve
   ```

Puis ouvrir l'URL http://localhost:4200 dans votre navigateur.

### Exécution des tests

#### Client

**Dépendances**

- Google Chrome ou Chromium

Dans votre terminal:

```shell
cd front
CHROME_BIN=</path/to/google/chrome> npm test
```

#### Serveur

Dans votre terminal:

```shell
cd back
./gradlew test
```

Sans autre réglage, la suite s'exécute sur une base **HSQLDB en mémoire** :
rien à installer, rien à démarrer.

##### Contre PostgreSQL, comme le fait la CI

PostgreSQL est le moteur cible d'un déploiement avec une base réelle, et c'est
sur lui que le job `test-back` exécute la suite. Les environnements Kubernetes
de démonstration tournent, eux, sur la base HSQLDB en mémoire de l'image
([DATABASE.md](./DATABASE.md)). Le choix du moteur ne tient à aucun profil ni
fichier de configuration : il tient aux trois variables standard de Spring.
Absentes, HSQLDB ; présentes, PostgreSQL.

```shell
# Une base jetable, qui disparaît avec le conteneur
docker run --rm -d --name microcrm-pg -p 5432:5432 \
  -e POSTGRES_DB=microcrm_test \
  -e POSTGRES_USER=microcrm \
  -e POSTGRES_PASSWORD=microcrm \
  postgres:16-alpine

cd back
SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/microcrm_test \
SPRING_DATASOURCE_USERNAME=microcrm \
SPRING_DATASOURCE_PASSWORD=microcrm \
  ./gradlew test

docker rm -f microcrm-pg
```

L'hôte est `localhost` ici parce que le port est publié sur la machine ; en CI
c'est `postgres`, l'alias du service GitLab. C'est la seule différence entre les
deux exécutions — voir [QUALITY.md](./QUALITY.md) §7 et
[DATABASE.md](./DATABASE.md).

#### Tests de performance (k6)

**Dépendances**

- [k6](https://k6.io/) — ou Docker, voir la variante plus bas.

Le serveur doit être démarré. Dans un autre terminal:

```shell
scripts/tests/run_k6.sh                      # test de fumée (défaut)
scripts/tests/run_k6.sh --scenario load      # charge nominale

# Sans installer k6
docker run --rm --network host -v "$PWD:/work" -w /work \
  -e K6_BASE_URL=http://localhost:8080 \
  grafana/k6:2.1.0 run tests/k6/smoke.js
```

Les scénarios sont dans `tests/k6/`, les seuils et la démarche dans
[QUALITY.md](./QUALITY.md) §5.

### Images Docker

Chaque application a **son propre Dockerfile**, dans son dossier. Il n'y a pas
de Dockerfile à la racine du dépôt, et pas d'image « tout en un ».

#### Le plus simple : la stack complète

```shell
docker compose up --build
```

Le front est servi sur http://localhost:4200, l'API sur http://localhost:8080.
Les ports et les noms d'images se règlent sans toucher au compose, via un
fichier `.env` — voir [`.env.example`](./.env.example).

#### Image du serveur

```shell
docker build -t microcrm-back ./back
docker run --rm -p 8080:8080 microcrm-back
```

L'API est disponible sur http://localhost:8080.

#### Image du client

```shell
docker build -t microcrm-front ./front
docker run --rm -p 4200:80 -e FRONT_API_BASE_URL=http://localhost:8080 microcrm-front
```

Le front est disponible sur http://localhost:4200. La variable
`FRONT_API_BASE_URL` est facultative : sans elle, le front vise
`http://localhost:8080`.

### Les choix de conteneurisation, et pourquoi

#### Une image par application, pas une image commune

Le front et le back n'ont ni le même cycle de vie, ni les mêmes dépendances, ni
la même charge. Les fusionner obligerait à redéployer l'un pour corriger
l'autre, et imposerait un superviseur de processus dans le conteneur — donc un
conteneur qui ne meurt plus quand son application meurt, ce qui prive
Kubernetes de son principal signal de panne.

#### Construction en plusieurs étapes

Chaque Dockerfile compile dans une image outillée (Gradle, Node) puis ne copie
que l'artefact dans une image d'exécution minimale. Ni le JDK, ni npm, ni les
sources ne se retrouvent dans l'image livrée. Chacun compte en réalité trois
étapes : le front recompile Caddy dans la sienne, et le back télécharge l'agent
OpenTelemetry dans une étape à part, où son empreinte SHA-256 est vérifiée. Le front pèse ainsi 85 Mo, dont
84,9 pour Caddy lui-même : l'application n'ajoute que quelques centaines de
kilo-octets.

#### Des versions figées, jamais `latest`

Les images de base sont épinglées (`gradle:8.14.5-jdk21`, `node:22-alpine`,
`caddy:2.11.4-builder-alpine`, `alpine:3.24`) et alignées sur les variables du
[`.gitlab-ci.yml`](./.gitlab-ci.yml) : le code est compilé avec la version
exacte qui a servi à le tester. Un tag flottant fait casser une construction
sans qu'aucun commit ne l'explique, et rend deux analyses incomparables. Les
versions restent surchargeables au build via `--build-arg`.

#### Un utilisateur non privilégié dans les deux images

Les deux conteneurs tournent en UID 1000, le même que celui déclaré dans les
manifestes Kubernetes : le comportement est identique sous Docker et sous
Kubernetes. Au déploiement s'ajoutent un système de fichiers en lecture seule et
la suppression de toutes les capabilities.

#### Un `.dockerignore` par application

Les jobs de construction utilisent `--context ./back` et `--context ./front`, or
Docker ne lit que le `.dockerignore` situé à la racine du contexte : celui du
dépôt ne s'applique jamais à ces builds. Sans ces deux fichiers, le contexte du
front atteint 1 195 Mo — essentiellement le cache Angular et `node_modules`, que
l'image régénère de toute façon. Avec, il tombe à 0,6 Mo.

#### La configuration entre au démarrage, pas à la construction

L'URL de l'API n'est pas compilée dans le bundle : Caddy la sert dans un
`/config.json` que l'application lit avant de démarrer. Une seule image est donc
construite, testée, puis déployée telle quelle en staging comme en production —
seule la variable d'environnement change. Reconstruire une image pour changer
d'environnement reviendrait à déployer autre chose que ce qui a été testé.

Le détail de ces choix est dans [ARCHITECTURE.md](./ARCHITECTURE.md) §3, et la
démarche de configuration dans [VARIABILISATION.md](./VARIABILISATION.md).
