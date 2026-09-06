# Guide de lecture du projet

Ce dépôt compte une douzaine de documents thématiques. Celui-ci n'en répète
aucun : il donne, pour chaque partie du projet, ce qu'elle fait, où elle vit, et
vers quel document aller pour le détail. Chaque section tient en dix lignes.

## 1. L'application

MicroCRM est un CRM de démonstration : des individus rattachés à des
organisations, en création, édition et consultation. Le back est une API REST
Spring Boot 3 exposée par Spring Data REST, avec une base HSQLDB **en mémoire**
alimentée au démarrage par une fixture — les données repartent donc de zéro à
chaque redémarrage. Le front est une application Angular servie par Caddy. Les
deux vivent dans le même dépôt (monorepo) et se déploient séparément.

**Fichiers** : `back/src/main/java/…/` (5 classes), `front/src/app/`,
`back/src/main/resources/application.properties`, `docker-compose.yml`
**Pour aller plus loin** : [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md), [DATABASE.md](DATABASE.md), [schema.md](schema.md)

## 2. Les tests du back

115 tests JUnit, exécutés par Gradle, qui produisent le rapport JaCoCo consommé
plus loin par la CI. Ils couvrent trois niveaux : les entités seules
(`PersonTest`, `OrganizationTest`), les dépôts sur une base réelle — HSQLDB en
mémoire par défaut, PostgreSQL dès que `SPRING_DATASOURCE_URL` est fournie, ce
que fait la CI — (`*RepositoryIntegrationTest`), et l'API HTTP de bout en bout
(`PersonRestApiTest`). Couverture actuelle : **97,40 % des lignes** et **100 %
des branches**, au-dessus du seuil bloquant de 95 % / 90 %.

**Fichiers** : `back/src/test/java/…/` (16 classes), `back/build.gradle` (tâche `test`, `jacocoTestReport`), `back/gradle.properties` (2 Go de tas, sans quoi l'analyse des dépendances manque de mémoire)
**Job CI** : `test-back`

## 3. Les tests du front

73 tests Karma/Jasmine exécutés dans un Chrome sans interface. Ils couvrent les
deux services qui parlent à l'API, les composants de détail, le routage, et
depuis peu le chargement de la configuration d'exécution (`config.spec.ts`,
10 tests sur les régimes de repli). Couverture : **100 % des lignes**,
88,6 % des branches. À savoir : **aucun job ne contrôle ce seuil** — le rapport
part vers SonarCloud, dont le verdict n'est relu que sur `main`. Le message
« Some of your tests did a full page reload! » est pré-existant et ne fait pas
échouer le job.

**Fichiers** : `front/src/app/*.spec.ts` (5 fichiers), `front/karma.conf.js`, `front/src/app/test-helpers.ts`
**Job CI** : `test-front`

## 4. Les tests des scripts d'automatisation

151 assertions qui vérifient les scripts du pipeline **avant** qu'ils ne servent
en production. Le principe : `kubectl`, `docker`, `trivy` et `k6` sont remplacés
par de faux programmes placés en tête du `PATH`, qui journalisent ce qu'on leur
demande et renvoient le code de sortie voulu. On peut ainsi tester les chemins
d'échec — déploiement raté, rollback raté, login refusé — sans cluster ni
registry. C'est là qu'est vérifié, par exemple, que le mot de passe du registry
passe par l'entrée standard et jamais en argument.

**Fichiers** : `scripts/tests/run_tests.sh`, `scripts/tests/stubs/`, `scripts/tests/fixtures/`
**Job CI** : `test-scripts` · **Détail** : [SCRIPTS.md](SCRIPTS.md)

## 5. La validation des manifestes Kubernetes

60 assertions dans le job `lint-k8s`, dont l'image n'a pas helm, et 108 dans
`lint-helm`, qui l'a. Elles construisent chaque overlay avec le Kustomize
embarqué dans `kubectl` et vérifient le rendu, **sans cluster**.
Elles attrapent ce qu'aucun validateur de schéma ne verrait : le contrat de
nommage avec `deploy.sh`, une ConfigMap référencée mais absente, une sonde
visant un port non déclaré, un patch d'overlay qui ne mord pas. `--autotest`
rejoue les assertions sur des rendus volontairement abîmés et vérifie qu'elles
échouent — une assertion
qui ne se déclenche jamais ne prouve rien. Limite : pas de validation de schéma,
faute de `kubeconform` dans l'image.

**Fichiers** : `scripts/tests/validate_k8s.sh`
**Job CI** : `lint-k8s`

## 6. Le pipeline CI/CD

30 jobs répartis en 9 étapes : `lint`, `test`, `quality`, `security`, `infra`,
`build`, `package`, `perf`, `deploy`. Deux jeux de règles pilotent l'ensemble : les jobs
de contrôle tournent sur toute branche `feature/*`, `release/*`, `hotfix/*`,
`develop`, `main` et les tags ; les jobs qui produisent ou déploient un artefact
sont réservés à `develop`, `main` et aux tags. Toutes les images d'outillage sont
épinglées à une version précise dans le bloc `variables:` — un tag flottant fait
casser un pipeline sans qu'aucun commit ne l'explique.

**Fichiers** : `.gitlab-ci.yml`, `scripts/ci/`, `.github/workflows/mirror-to-gitlab.yaml`
**Détail** : [QUALITY.md](QUALITY.md), [RELEASE.md](RELEASE.md)

## 7. La qualité du code

Quatre contrôles complémentaires. Checkstyle et ESLint sur le style, SpotBugs sur
les défauts de programmation Java, SonarCloud sur la dette et les vulnérabilités,
un seuil de couverture et des tests de mutation sur le back. Deux points à
connaître : `coverage-gate` est **bloquant** (`allow_failure: false`), là où
`mutation-back` informe ; et `quality-gate` ne tourne que sur `main`, parce que
le plan gratuit de SonarCloud refuse de livrer le verdict des autres branches.
Les analyses, elles, sont bien envoyées depuis toutes les branches.

**Fichiers** : `back/config/checkstyle/`, `back/config/spotbugs/`, `front/.eslintrc.json`, `front/sonar-project.properties`, `scripts/ci/check_coverage.py`, `scripts/ci/quality_gate.py`
**Jobs CI** : `lint-back`, `lint-front`, `spotbugs-back`, `sonar-back`, `sonar-front`, `coverage-gate`, `mutation-back`, `quality-gate`

## 8. La sécurité

Trois angles. Dependency-Check confronte les dépendances du back à la base NVD
des vulnérabilités connues. Trivy scanne le dépôt à la recherche de dépendances
vulnérables, de secrets oubliés et de mauvaises configurations, et scanne aussi
les images avant leur envoi au registry. Les conteneurs déployés tournent en
utilisateur non privilégié, système de fichiers en lecture seule et sans aucune
capability. `dependency-check-back` est **bloquant** depuis qu'il aboutit et
ne trouve aucune vulnérabilité ; `trivy-fs` renseigne encore sans bloquer.

**Fichiers** : `back/config/dependency-check/suppressions.xml`, `.trivyignore`, `scripts/ci/build_and_push.sh`, `k8s/base/*-deployment.yaml`
**Jobs CI** : `dependency-check-back`, `trivy-fs` · **Détail** : [AUDIT.md](AUDIT.md)

## 9. La performance

Trois scénarios k6, du plus léger au plus exigeant : `smoke` vérifie que l'API
répond, `load` mesure sous charge nominale, `stress` cherche le point de rupture.
Les seuils vivent dans les scénarios eux-mêmes, pas dans la CI, pour que la
commande locale et le job mesurent exactement la même chose. `lib/config.js` est
la référence du dépôt en matière de configuration : un défaut utilisable, une
surcharge par environnement, et une erreur explicite si la valeur est illisible
plutôt qu'un `NaN` silencieux qui fausserait la mesure.

**Fichiers** : `tests/k6/{smoke,load,stress}.js`, `tests/k6/lib/`, `scripts/tests/run_k6.sh`
**Jobs CI** : `k6-smoke`, `k6-load`, `k6-stress` · **Détail** : [QUALITY.md](QUALITY.md) §5

## 10. Le déploiement Kubernetes

L'état voulu du cluster est décrit en manifestes Kustomize versionnés : une base
commune, deux overlays qui ne diffèrent que par ce qui doit différer (replicas,
hôtes, origines CORS, ressources). La CI applique l'overlay, crée le Secret
d'accès au registry, puis pose l'image du commit ; `deploy.sh` attend la fin du
rollout et revient en arrière tout seul en cas d'échec. Les manifestes ont été
appliqués sur un cluster réel le 10 août 2026, rollback compris ([K8S.md](K8S.md)
§14) ; le back reste plafonné à 1 replica tant que la base vit en mémoire.

**Fichiers** : `k8s/base/`, `k8s/overlays/{staging,production}/`, `scripts/deploy/`
**Jobs CI** : `deploy-staging`, `deploy-production`, `rollback-production` · **Détail** : [K8S.md](K8S.md)

## 11. La configuration

Aucune valeur dépendant de l'environnement n'est écrite en dur. Les versions
d'outillage et les réglages partagés vivent dans le `.gitlab-ci.yml` ; les
secrets et les coordonnées d'infrastructure restent dans l'interface GitLab ; ce
qui varie entre staging et production vit dans les overlays Kustomize. Le front
lit son URL d'API **au démarrage** et non à la compilation, ce qui permet de
construire une seule image et de la déployer partout. Chaque réglage garde un
défaut fonctionnel, pour que le projet démarre en local sans configuration.

**Fichiers** : `.gitlab-ci.yml` (bloc `variables:`), `.env.example`, `docker-compose.yml`, `front/Caddyfile`, `front/src/app/config.ts`, `k8s/base/configmap.yaml`
**Détail** : [VARIABILISATION.md](VARIABILISATION.md)

## 12. Les conventions de contribution

Deux crochets Git protègent le dépôt avant même la CI. Le premier formate les
fichiers modifiés et lance les contrôles adaptés à chaque type de fichier ; le
second refuse les messages de commit hors format Conventional Commits. Les types
autorisés et le flux de branches sont documentés à part. L'intérêt est de faire
échouer au plus tôt ce qui échouerait de toute façon dans la CI, quand la boucle
de retour se compte en secondes plutôt qu'en minutes.

**Fichiers** : `.husky/pre-commit`, `.husky/commit-msg`, `lint-staged.config.js`, `commitlint.config.js`, `.prettierrc.json`, `.prettierignore`
**Détail** : [RELEASE.md](RELEASE.md), [VEILLE.md](VEILLE.md)
