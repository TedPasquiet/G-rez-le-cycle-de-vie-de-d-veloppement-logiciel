# Qualité, sécurité et supervision

Ce document est le plan de tests et de sécurité de MicroCRM : quels contrôles
existent, quand ils tournent, ce qu'ils exigent pour laisser passer une
livraison, et comment les rejouer. Chaque outil voit ce que les autres ne voient
pas : un test unitaire ne détecte pas une CVE, un scan de CVE ne détecte pas une
mauvaise pratique de code, et aucun des deux ne dit si l'application tient la
charge.

| Outil                      | Question à laquelle il répond                                                  | Où il s'exécute              |
| -------------------------- | ------------------------------------------------------------------------------ | ---------------------------- |
| **SonarQube / SonarCloud** | Le code respecte-t-il les bonnes pratiques ? Quelle est la dette ?             | stage `quality`              |
| **SpotBugs**               | Y a-t-il des bugs latents dans le bytecode ?                                   | stage `quality`              |
| **OWASP Dependency-Check** | Les dépendances Java portent-elles des CVE connues ?                           | stage `security`             |
| **Trivy**                  | Les images et les fichiers du dépôt portent-ils des CVE, secrets, misconfigs ? | stages `security`, `package` |
| **k6**                     | L'API répond-elle correctement, et assez vite, sous charge ?                   | stage `perf`                 |
| **JaCoCo + PIT**           | Les tests couvrent-ils le code, et vérifient-ils quelque chose ? (§7)          | stages `test` et `quality`   |
| **Stack ELK + APM**        | Que fait l'application une fois déployée ?                                     | hors CI, §6                  |

S'y ajoutent les contrôles de forme. **En CI**, au stage `lint` : **Checkstyle**
côté back, **ESLint** côté front, **ShellCheck** sur les scripts, la validation
des manifestes Kubernetes et du chart Helm, la concordance des versions sur un
tag. **En local, avant chaque commit**, les hooks **husky** lancent
`lint-staged` (ESLint et **Prettier** sur le front et la documentation,
**Spotless** sur le Java) et **commitlint** vérifie le message.

Le pipeline compte 10 stages : `lint` → `test` → `quality` → `security` →
`infra` → `build` → `package` → `perf` → `deploy` → `infra-apply` (voir
[ARCHITECTURE.md](ARCHITECTURE.md) §4). `infra` valide Terraform et Ansible
**avant** toute compilation, parce qu'un plan cassé n'a pas besoin d'attendre
Gradle pour être signalé ; `infra-apply` est en dernier parce que ses jobs
manuels bloqueraient tout ce qui les suit.

## Le plan en un tableau

**Fréquence.** Les contrôles de code (`lint`, `test`, `quality`, `security`)
tournent sur chaque merge request, chaque branche `feature/`, `fix/`, `docs/`,
`release/`, `hotfix/`, et sur `develop`, `main` et les tags. Sur une merge
request ou une branche de travail, les jobs du back et du front ne tournent que
si leur dossier (ou le pipeline) a changé. Les étapes `build`, `package` et
`perf` tournent sur `develop`, `release/*`, `hotfix/*`, `main` (et les tags pour
`build` et `perf`).

| Type de contrôle                      | Outil, job                                              | Critère de validation                                            | Bloquant                 |
| ------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------ |
| Style et règles statiques             | Checkstyle, ESLint, ShellCheck (`lint-*`, `shellcheck`) | aucune violation                                                 | oui                      |
| Manifestes et chart                   | `lint-k8s`, `lint-helm`                                 | toutes les assertions de `validate_k8s.sh` passent               | oui                      |
| Concordance des versions              | `version-consistency` (tag)                             | les trois fichiers de version portent le numéro du tag           | oui                      |
| Tests unitaires et d'intégration back | JUnit sur PostgreSQL (`test-back`)                      | 0 test en échec                                                  | oui                      |
| Tests unitaires front                 | Karma (`test-front`)                                    | 0 test en échec ; lignes ≥ 90 %, branches ≥ 80 %                 | oui                      |
| Tests des scripts                     | `test-scripts`                                          | 430 assertions, 0 en échec                                       | oui                      |
| Couverture back                       | JaCoCo (`coverage-gate`)                                | lignes ≥ `COVERAGE_MIN` (90 %)                                   | oui                      |
| Force des assertions                  | PIT (`mutation-back`)                                   | mutants tués ≥ `MUTATION_MIN` (80 %)                             | oui                      |
| Qualité du code                       | Sonar (`sonar-*`, `quality-gate`)                       | analyse envoyée ; Quality Gate franchie (sur `main`)             | oui                      |
| Bugs du bytecode                      | SpotBugs (`spotbugs-back`)                              | rapport publié                                                   | non                      |
| CVE des dépendances Java              | Dependency-Check (`dependency-check-back`)              | aucune CVE de score CVSS ≥ 7 non exceptée                        | oui                      |
| Dépôt : CVE, secrets, misconfigs      | Trivy (`trivy-fs`)                                      | aucun constat HIGH ou CRITICAL non excepté                       | oui                      |
| CVE des images                        | Trivy dans `package-back`, `package-front`              | aucun constat HIGH ou CRITICAL ; sinon l'image n'est pas poussée | oui                      |
| Fumée sur l'image livrée              | k6 (`k6-smoke`)                                         | tous les checks passent ; p95 < 1 500 ms ; erreurs < 1 %         | oui                      |
| Charge nominale                       | k6 (`k6-load`)                                          | p95 lectures < 500 ms, écritures < 800 ms ; erreurs < 1 %        | non (runners mutualisés) |
| Point de rupture                      | k6 (`k6-stress`), sur demande                           | seuils de rupture de `stress.js`                                 | oui, quand il est lancé  |
| Disponibilité en service              | Kibana, 8 règles d'alerte (§6)                          | alerte levée dans Kibana                                         | hors CI                  |

Pour tout ce qui est bloquant, un échec arrête le pipeline. Les deux exceptions
sont **`k6-load`** (§5 : ses mesures varient d'une exécution à l'autre sur des
runners mutualisés, et un seuil dur y produirait des échecs sans rapport avec le
code) et **`spotbugs-back`** (§2 : `ignoreFailures = true`, le job publie son
rapport sans faire échouer le pipeline).

---

## 1. SonarQube — bonnes pratiques et dette technique

**Pourquoi.** C'est le filet de sécurité principal pour une équipe peu
expérimentée en Java : Sonar connaît les idiomes du langage et de Spring, et
signale ce qu'une relecture peu expérimentée laisse passer (ressources non
fermées, `equals` sans `hashCode`, complexité cyclomatique, duplication, code
mort). Il agrège aussi la **couverture de tests** (JaCoCo côté back, LCOV côté
front) et applique une **Quality Gate** au nouveau code.

**Mise en place.**

- Back : plugin Gradle `org.sonarqube` + `jacoco`, configurés dans `back/build.gradle`.
- Front : `front/sonar-project.properties`, analysé par `sonar-scanner-cli`.

**Serveur local.**

```shell
docker compose -f docker-compose.sonar.yml up -d
# http://localhost:9000 — admin / admin au premier démarrage
```

Générer ensuite un token dans l'interface (_My Account → Security_), puis :

```shell
cd back
./gradlew test jacocoTestReport sonar \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.token=<votre-token>
```

```shell
cd front
npx @angular/cli test --no-watch --code-coverage
sonar-scanner -Dsonar.host.url=http://localhost:9000 -Dsonar.token=<votre-token>
```

**En CI.** Deux jobs envoient l'analyse au stage `quality` : `sonar-back` (plugin
Gradle) et `sonar-front` (`sonar-scanner-cli`). Ils ont besoin des variables CI/CD
`SONAR_HOST_URL` et `SONAR_TOKEN` ; sans elles ils échouent, et le pipeline avec
eux.

Le verdict de la Quality Gate est lu par le job **`quality-gate`**, qui appelle
[`scripts/ci/quality_gate.py`](scripts/ci/quality_gate.py) une fois par projet
Sonar (back et front). Le script interroge l'API jusqu'à obtenir le résultat,
puis sort en `2` si la porte n'est pas franchie, en affichant les règles
fautives. **Ce job ne tourne que sur `main`** : l'offre gratuite de SonarCloud
n'expose le Quality Gate que pour la branche principale (l'API répond `403` sur
les autres). Les analyses, elles, sont envoyées depuis toutes les branches. Voir
[SCRIPTS.md](SCRIPTS.md).

---

## 2. SpotBugs — bugs potentiels

**Pourquoi.** SpotBugs analyse le **bytecode compilé**, pas le texte du source. Il
détecte donc des choses qu'aucun linter ne voit : déréférencement null sur un chemin
d'exécution particulier, comparaison de `String` avec `==`, flux non fermés, retours
ignorés.

Le module **Find-Sec-Bugs**, qui ajouterait environ 140 motifs de sécurité
(injection SQL, XSS, CORS permissif, cryptographie faible), n'est **pas**
branché : SpotBugs tourne avec ses règles par défaut. L'ajouter tient en une
ligne `spotbugsPlugins` dans `back/build.gradle` ; c'est une piste, pas un
contrôle en place. Le CORS de l'API est configuré dans
`SpringDataRestCustomization.java` : une liste d'origines explicite,
surchargeable par `MICROCRM_CORS_ALLOWED_ORIGINS`, jamais `*`.

**Utilisation locale.**

```shell
cd back
./gradlew spotbugsMain
open build/reports/spotbugs/spotbugsMain.html
```

**Configuration.** `back/config/spotbugs/exclude.xml` filtre les faux positifs connus
(entités JPA, classe `Application`). Le job CI est en `ignoreFailures = true` : les
constats sont publiés en artefact sans casser le pipeline. Passer ce drapeau à
`false` dans `back/build.gradle` rend le contrôle bloquant.

---

## 3. OWASP Dependency-Check — CVE des dépendances

**Pourquoi.** La majorité du code livré n'a pas été écrite par l'équipe : c'est celui
de Spring, Hibernate, Jackson, Tomcat. Dependency-Check confronte l'arbre de
dépendances Gradle à la base **NVD** et signale les CVE publiées.

**Utilisation locale.**

```shell
cd back
./gradlew dependencyCheckAnalyze
open build/reports/dependency-check/dependency-check-report.html
```

> La première exécution télécharge la base NVD (long). Une **clé API NVD** gratuite
> ([demander une clé API NVD](https://nvd.nist.gov/developers/request-an-api-key))
> réduit ce temps d'environ 10 min à environ 1 min. La déclarer en variable
> d'environnement `NVD_API_KEY` (et en variable CI/CD masquée dans GitLab).

**Seuil.** `failBuildOnCVSS = 7` : la tâche échoue dès qu'une dépendance porte une
vulnérabilité de sévérité HIGH ou CRITICAL. Le job CI est bloquant : une CVE publiée
pendant la nuit arrête la livraison suivante, et c'est un arbitrage humain (mise à
jour, ou exception justifiée et datée) qui la débloque.

**Périmètre analysé.** `scanConfigurations = ['runtimeClasspath']` et
`skipTestGroups = false`. Le second réglage est indispensable : le plugin écarte
par défaut les configurations « de test » en les reconnaissant à leur nom, et le
plugin Spring Boot fait hériter `runtimeClasspath` de `testAndDevelopmentOnly`.
Sans lui, le scan ne lit aucun jar et sort vert. Les dépendances de test
n'entrent pas pour autant, puisque seule `runtimeClasspath` est nommée. Un job
vert se vérifie donc aussi par ce qu'il a regardé : le rapport doit lister les
dépendances analysées (82 aujourd'hui).

**Exceptions.** Documentées et datées dans
`back/config/dependency-check/suppressions.xml`, qui fait foi ; jamais ignorées
silencieusement. Processus décrit dans [AUDIT.md](AUDIT.md) §7.4.

| Constat                                | Traitement                                                                                                                                      |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| CVE-2026-34479, Log4j 2.24.3           | **Corrigé** : Log4j forcé à 2.25.5 (`ext['log4j2.version']`)                                                                                    |
| CVE de `jackson-databind`              | **Corrigé** : BOM Jackson forcé à 2.21.7 (`ext['jackson-bom.version']`)                                                                         |
| 6 CVE de Spring WebFlux et RSocket     | **Exceptées** jusqu'au 2026-12-31 : ces modules ne sont pas sur le `runtimeClasspath`                                                           |
| 3 CVE de fonctions Spring MVC          | **Exceptées** jusqu'au 2026-12-31 : `XsltView`, Server-Sent Events et framework fonctionnel, que l'application n'utilise pas (aucun contrôleur) |
| 3 CVE de SpEL et de liaison de données | **Exceptées** jusqu'au 2026-12-31, après analyse condition par condition contre les avis de Spring, et un contrôle par exécution sur staging    |

**Pourquoi des exceptions et non une montée de version de Spring.** La version
corrigée de la branche 6.2 (6.2.20) n'est pas publiée sur Maven Central : les
avis de Spring la réservent au support payant. Le seul correctif en source
ouverte est Spring Framework 7, c'est-à-dire **Spring Boot 4**, une migration
majeure. Attendre ne lèverait donc rien.

**État mesuré.** Dans les pipelines #2909284076, #2912362926 et #2913490784
(3 au 5 octobre 2026), `dependency-check-back` est vert : 82 dépendances
analysées, 12 CVE exceptées, **aucune CVE de score 7 ou plus ouverte**. Six CVE
de score inférieur à 7 (de 3,7 à 6,5) restent visibles dans le rapport, sous le
seuil donc non bloquantes ([AUDIT.md](AUDIT.md) §7.4.5).

**Limites.**

- Les trois dernières exceptions reposent sur une analyse, pas sur un
  correctif : elles tombent le jour où le modèle reçoit un champ `BigDecimal`,
  une liste auto-peuplée, ou que le compilateur SpEL est activé.
- Il n'existe **pas** d'équivalent côté front : aucun job ne lance `npm audit`.
  Les dépendances npm ne sont couvertes que par `trivy-fs`, qui lit le
  `package-lock.json`.

---

## 4. Trivy — CVE des images Docker, secrets et misconfigurations

**Pourquoi.** Dependency-Check ne voit que les dépendances Java. L'image livrée
contient aussi un OS (Alpine), une JRE, un serveur web (Caddy), chacun avec ses
propres CVE. Trivy scanne les **couches système** de l'image finale, et détecte
en plus les **secrets commités** et les **mauvaises configurations** (Dockerfile,
manifestes Kubernetes).

**Deux portées.**

- Le job **`trivy-fs`** (stage `security`, rapide) scanne le dépôt : dépendances
  déclarées, secrets oubliés, misconfigurations.
- Le **scan des images** a lieu dans `package-back` et `package-front`,
  **entre** la construction de l'image et son envoi au registry
  (`build_and_push.sh --scan`). Une image refusée n'atteint pas le registry, et
  ne peut donc pas être promue par un tag de version.

**Les deux sont bloquants**, sur `HIGH,CRITICAL`, à travers
`scripts/ci/trivy_scan.sh`, qui fait deux passages : un **relevé** en JSON, sans
porte, puis la **porte**, au format tableau. Son code de sortie distingue un
constat (`2`) d'un scan impossible (`1`) ; le job échoue dans les deux cas.
`trivy-fs` passe `--ignorefile .trivyignore.yaml` : Trivy ne lit que
`.trivyignore` par défaut, et sans ce drapeau les exclusions ne s'appliquent
pas.

**Exceptions.** `.trivyignore.yaml` porte 7 entrées (misconfigurations HIGH des
manifestes Kubernetes, du RBAC de l'agent GitLab et du Dockerfile du back), une
par identifiant **et** par chemin, chacune justifiée et à revoir au 2026-12-31.

**Les rapports sont publiés en artefacts**, que le job réussisse ou non
(`when: always`, une semaine) :

| Job             | Artefacts                                                         |
| --------------- | ----------------------------------------------------------------- |
| `trivy-fs`      | `reports/trivy-fs.json`, `reports/trivy-fs.txt`                   |
| `package-back`  | `reports/trivy-image-back.json`, `reports/trivy-image-back.txt`   |
| `package-front` | `reports/trivy-image-front.json`, `reports/trivy-image-front.txt` |

Ils sont **filtrés comme la porte** (HIGH et CRITICAL, exclusions appliquées) :
ils décrivent ce que la porte a vu, pas tout ce que Trivy sait.
`scripts/ci/collect_security.py` les indexe pour le tableau de bord « sécurité »
([SCRIPTS.md](SCRIPTS.md)).

**État mesuré.** Le scan du dépôt sort à 0 constat une fois les exclusions
appliquées. Les images `back:08a216b0` et `front:08a216b0`, promues en `1.0.1`
et en production depuis le 5 octobre 2026, portent 0 constat HIGH ou CRITICAL
dans les rapports de leur pipeline. Le registry conserve une image plus
ancienne, `back:5bf1d6a2`, qui porte 5 CVE HIGH de Jackson : elle n'est déployée
nulle part.

**Utilisation locale** :

```shell
# Scan du dépôt, par le script du pipeline (Trivy installé), rapport compris
scripts/ci/trivy_scan.sh --mode fs --target . --report reports/trivy-fs.json \
  --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
  --ignorefile .trivyignore.yaml

# Le même scan sans rien installer — même version que le pipeline
docker run --rm -v "$PWD:/scan" -w /scan aquasec/trivy:0.69.3 \
  fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
  --ignorefile .trivyignore.yaml \
  --skip-dirs front/node_modules --skip-dirs back/build .

# Scan d'une image construite
docker build -t microcrm-back:local ./back
scripts/ci/trivy_scan.sh --mode image --target microcrm-back:local \
  --report reports/trivy-image-back.json --docker-image aquasec/trivy:0.69.3
```

---

## 5. k6 — tests de performance

**Pourquoi.** Tous les contrôles précédents lisent du code ou des dépendances :
aucun ne lance l'application. Un pipeline entièrement vert peut livrer une API
qui s'écroule à dix utilisateurs. k6 joue de vraies requêtes HTTP sur
l'application démarrée, et compare les temps de réponse à un budget écrit dans
le dépôt.

**Pourquoi k6 plutôt que JMeter** : les scénarios s'écrivent en JavaScript
(relisibles en revue de code, versionnés à côté du reste), k6 s'exécute dans un
simple conteneur, et il sort en erreur tout seul quand un seuil est dépassé, ce
qui en fait une porte de CI et pas seulement un rapport.

**Ce qui est testé.** Le back, à travers son API REST : liste des personnes,
fiche d'une personne, organisations liées, liste des organisations, recherche par
email, puis création et suppression d'une fiche. **Chaque réponse est vérifiée
fonctionnellement** (statut HTTP _et_ contenu attendu) : un serveur qui renvoie
« 500 » en 3 ms est rapide et cassé. Les scénarios envoient l'en-tête `Accept`
comme le front Angular, parce que Spring Data REST ne renvoie le corps de la
ressource créée qu'avec cet en-tête.

### Les trois scénarios

| Fichier              | Ce qu'il fait                                                                  | Rôle                        |
| -------------------- | ------------------------------------------------------------------------------ | --------------------------- |
| `tests/k6/smoke.js`  | 1 utilisateur, 5 parcours complets (lecture + écriture)                        | « est-ce que ça marche ? »  |
| `tests/k6/load.js`   | Charge nominale : 10 utilisateurs en lecture + 2 écritures/s pendant le palier | garde-fou des temps réponse |
| `tests/k6/stress.js` | Montée par paliers jusqu'à 50 utilisateurs, sans pause                         | trouver le point de rupture |

`load.js` fait tourner deux populations **en même temps**, plus fidèle qu'un
parcours moyen unique : un CRM lit beaucoup plus qu'il n'écrit. Les lectures
montent progressivement avec une pause entre deux clics ; les écritures partent
à un rythme fixe (2/s) une fois le palier atteint. Si l'API ralentit, la charge
d'écriture ne baisse pas toute seule, et le problème se voit.

### Le budget de performance

Les seuils vivent dans `tests/k6/lib/config.js` et sont surchargeables par
variable d'environnement, pour explorer en local. **Convention d'équipe : aucune
variable de seuil dans GitLab**, car une porte dont on desserre le seuil depuis
l'interface n'est plus une porte. Les variables CI/CD règlent la charge
(`K6_LOAD_VUS`, `K6_LOAD_DURATION`…), pas le budget.

| Seuil                             | Valeur par défaut | Variable            |
| --------------------------------- | ----------------- | ------------------- |
| p95 des lectures                  | 500 ms            | `K6_P95_READ_MS`    |
| p95 des écritures                 | 800 ms            | `K6_P95_WRITE_MS`   |
| Taux de requêtes en erreur        | < 1 %             | `K6_ERROR_RATE_MAX` |
| p95 du smoke (application froide) | 1500 ms           | `K6_P95_SMOKE_MS`   |

Des **percentiles et pas des moyennes** : une moyenne correcte peut cacher 5 %
d'utilisateurs qui attendent trois secondes. **Un seuil par endpoint** plutôt
qu'un seuil global : il permet de dire « c'est la recherche par email qui
décroche » au lieu de « c'est lent ». Le budget du smoke est large parce que ce
scénario tourne juste après le démarrage du conteneur, quand la JVM n'a encore
rien optimisé ; ce sont les seuils de `load.js` qui font foi.

### Dans la CI

Le stage `perf` s'exécute **après `package`** : GitLab démarre l'image Docker qui
vient d'être construite comme un **service** (accessible sur `http://back:8080`),
et k6 tourne dans le conteneur du job pour l'interroger. On mesure donc
l'artefact qui partira en production, sans Docker in Docker. Les jobs k6
tournent dans un pipeline enfant, déclenché par le job `perf`.

| Job         | Scénario    | Bloquant ?                  |
| ----------- | ----------- | --------------------------- |
| `k6-smoke`  | `smoke.js`  | **oui**                     |
| `k6-load`   | `load.js`   | non (`allow_failure: true`) |
| `k6-stress` | `stress.js` | **oui**, lancé sur demande  |

`k6-load` n'est pas bloquant parce que les runners partagés sont mutualisés :
leurs mesures varient, et un seuil dur y produirait des échecs aléatoires. Sur
un runner dédié, passer `allow_failure` à `false` en fait une vraie porte.

`k6-stress` cherche volontairement la rupture : il ne tourne que si le pipeline
est lancé à la main (« New pipeline ») avec `K6_STRESS=true`, sur `develop`,
`main` ou un tag. Il exige, dans Settings → CI/CD → Variables, « Minimum role to
use pipeline variables » réglé sur Developer (sur « No one allowed », le
formulaire n'affiche pas la section Variables). Il n'est pas en `when: manual`,
car un job manuel sans `allow_failure` bloquerait le pipeline enfant et le
déploiement derrière lui. S'il franchit ses seuils de rupture, ce pipeline-là
passe au rouge.

L'attente du démarrage de l'application est gérée par les scénarios (fonction
`setup`, jusqu'à `K6_READY_TIMEOUT_S` secondes), et non par un `sleep` dans le
pipeline. Ces requêtes d'attente sont marquées comme normales quel que soit leur
statut, pour ne pas fausser le taux d'erreur.

**Pas de rapport JSON en artefact** : l'image `grafana/k6` s'exécute avec un
utilisateur non root, qui peut lire le dépôt cloné mais pas y écrire. Le résumé
complet (seuils, percentiles par endpoint, checks) se lit dans le **journal du
job**. Pour un rapport exploitable, `scripts/tests/run_k6.sh` écrit un JSON en
local. Pour voir les journaux de l'application quand un job échoue, définir la
variable CI/CD `CI_DEBUG_SERVICES` à `"true"`.

L'image k6 est **figée** (`grafana/k6:2.1.0`), comme tous les outils du
pipeline : d'une version à l'autre, les mesures ne seraient plus comparables.

### Utilisation locale

```shell
# Démarrer l'API dans un terminal
cd back && ./gradlew build && java -jar build/libs/microcrm-*.jar

# Puis, dans un autre terminal
scripts/tests/run_k6.sh                          # smoke (défaut)
scripts/tests/run_k6.sh --scenario load
K6_LOAD_VUS=25 scripts/tests/run_k6.sh -s load   # charge plus forte

# Sans installer k6, en reproduisant exactement ce que fait la CI
docker run --rm --network host -v "$PWD:/work" -w /work \
  -e K6_BASE_URL=http://localhost:8080 \
  grafana/k6:2.1.0 run tests/k6/smoke.js
```

`scripts/tests/run_k6.sh` est un raccourci : toute la logique (charge, seuils,
parcours) est dans `tests/k6/*.js`, de sorte que la commande locale et le job CI
mesurent la même chose. Voir [SCRIPTS.md](SCRIPTS.md) pour ses options et ses
codes de sortie.

### Limites

- Les mesures dépendent de la machine : elles détectent une **régression** entre
  deux exécutions comparables, pas une capacité absolue.
- k6 attaque l'**image livrée**, démarrée en service sans variable
  `SPRING_DATASOURCE_*`, donc sur sa base HSQLDB en mémoire, plus rapide qu'une
  base réseau : les chiffres sont optimistes en valeur absolue. La suite de tests
  du back, elle, s'exécute sur PostgreSQL (§7) : ici on mesure une tendance, là
  on vérifie un comportement.
- Le front n'est pas testé en charge (ce serait le rôle d'un Lighthouse CI) :
  c'est le back qui porte le risque de saturation.

---

## 6. Supervision de l'application déployée

Les contrôles précédents agissent **avant** le déploiement. La supervision dit
si l'application déployée répond, si sa base est joignable et ce qu'elle
journalise. Le détail est dans [MONITORING.md](MONITORING.md).

| Volet                                   | État                        | Détail                                                                                                                                                                                                                                                                                                                                                                       |
| --------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sondes de santé                         | en place                    | Actuator expose `health` seul (`management.endpoints.web.exposure.include=health`, détails masqués) : exposer `env`, `beans` ou `heapdump` divulguerait la configuration interne. Trois sondes (`startup`, `liveness`, `readiness`) sur les deux Deployments : un rollout dont l'application ne répond pas échoue, et `deploy.sh` revient en arrière — [K8S.md](K8S.md) §5   |
| Centralisation des logs                 | en place, staging seul      | Elasticsearch, Kibana et Filebeat sur le cluster local ; les logs du back sont en JSON ECS et arrivent décodés. Filebeat ne collecte pas la production                                                                                                                                                                                                                       |
| Tableaux de bord                        | en place                    | Cinq tableaux de bord versionnés dans `k8s/elk/dashboards/` : supervision, DORA, sécurité, disponibilité, suivi des alertes — [MONITORING.md](MONITORING.md) §8                                                                                                                                                                                                              |
| Alerting                                | en place, sans notification | Huit règles Kibana versionnées (disponibilité, performance, sécurité), installées par `scripts/monitoring/install_alerting.py`, toutes déclenchées une fois le 2 octobre 2026. Elles écrivent dans l'index `microcrm-alerts` et le journal de Kibana ; **rien ne sort de Kibana**, les connecteurs webhook exigeant une licence payante — [MONITORING.md](MONITORING.md) §11 |
| Latence, débit et taux d'échec de l'API | en place, sans recul        | Traces OpenTelemetry vers Elastic APM, émises par les pods de staging et de production depuis le 5 octobre 2026 — [MONITORING.md](MONITORING.md) §10                                                                                                                                                                                                                         |
| Métriques de ressources (CPU, mémoire)  | **absent**                  | Ni Prometheus ni `metrics-server` sur le cluster ; les métriques JVM de l'agent sont coupées. Les `resources` des Deployments restent des estimations. Piste : `micrometer-registry-prometheus` exposerait `/actuator/prometheus`                                                                                                                                            |

---

## 7. Les tests — couverture, et force des assertions

### Ce que chaque niveau vérifie

| Niveau                     | Où                                                                                                                   | Ce qu'il attrape                                                                                                    |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Unitaires (back)           | `PersonTest`, `OrganizationTest`, `InitialDataFixtureTest`, `SpringDataRestCustomizationTest`                        | Logique des entités et de la configuration, sans base ni contexte Spring. Quelques millisecondes.                   |
| Intégration JPA            | `*RepositoryIntegrationTest`, `PersonDeletionIntegrationTest`                                                        | Ce que fait réellement Hibernate : cascades, table de jointure, contraintes, hook `@PreRemove`.                     |
| Contrat HTTP               | `PersonRestApiTest`, `PersonRestLifecycleTest`, `OrganizationRestApiTest`, `CorsPolicyTest`, `ActuatorEndpointsTest` | Les endpoints que Spring Data REST **génère**, donc ceux qu'aucune ligne du dépôt ne décrit.                        |
| Configuration variabilisée | `CorsAllowedOriginsOverrideTest`                                                                                     | Que la surcharge par variable d'environnement est bien lue, et que le défaut de développement cesse de s'appliquer. |
| Unitaires (front)          | `*.service.spec.ts`, `*.component.spec.ts`, `config.spec.ts`                                                         | Les requêtes réellement émises (URL, méthode, en-têtes) et l'enchaînement des appels.                               |
| Scripts                    | `scripts/tests/run_tests.sh`                                                                                         | Les scripts d'automatisation, avec `kubectl`, `docker`, `terraform`… remplacés par des stubs.                       |
| Manifestes                 | `scripts/tests/validate_k8s.sh`                                                                                      | Le rendu des overlays Kustomize et du chart Helm, sans cluster.                                                     |
| Charge                     | `tests/k6/`                                                                                                          | Le comportement sous charge, budget de performance à l'appui (§5).                                                  |

Le niveau « contrat HTTP » est essentiel : l'API n'a **aucun contrôleur**. Les
URL, les codes de retour et la sémantique des liens d'association viennent
entièrement de Spring Data REST. Ni le compilateur, ni Checkstyle, ni SpotBugs
ne voient ces endpoints : les tests sont leur seule description exécutable.

### Sur quel moteur de base ces tests s'exécutent

**En CI : un PostgreSQL réel**, démarré comme service du job (`postgres:16-alpine`,
version figée dans `.gitlab/ci/variables.yml` comme les autres images). **En
local : HSQLDB en mémoire**, sans rien à installer.

Cette répartition tient deux exigences à la fois : `cd back && ./gradlew test`
reste lançable sur un poste nu, et le code rencontre le moteur de production
avant la production. Le schéma n'est écrit nulle part (Hibernate le déduit des
entités), or ce qu'un moteur tolère, l'autre le refuse : types rapprochés, casse
des identifiants, ordre de tri sans `ORDER BY`, moment où une contrainte est
vérifiée. Une suite verte sur HSQLDB ne dit rien de PostgreSQL.

La bascule ne passe par aucun profil Spring, mais par les trois variables
standard `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME` et
`SPRING_DATASOURCE_PASSWORD` : absentes, HSQLDB ; présentes, PostgreSQL. Il n'y
a pas de profil à oublier d'activer : c'est l'environnement qui décide, et le
même mécanisme sert au déploiement. [README.md](README.md) donne la commande
pour reproduire l'exécution CI sur un poste.

Deux jobs reçoivent ce service, `test-back` et `mutation-back` :

| Job             | Pourquoi le service                                                                                                                                                                                                                                   |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test-back`     | Il exécute la suite, et son rapport JaCoCo alimente tout le stage `quality`.                                                                                                                                                                          |
| `mutation-back` | PIT rejoue la suite **une fois par mutant** : sans le service, il publierait un score de mutation mesuré sur un moteur qu'on ne déploie pas. Le job y perd en durée (il porte pour cela un `timeout` explicite) et y gagne de mesurer ce qu'on livre. |

Les autres jobs du back ne relancent aucun test : `sonar-back` lit les classes
compilées et le XML JaCoCo repris en artefact, `coverage-gate` lit ce même XML,
`spotbugs-back` analyse du bytecode, `dependency-check-back` résout le
`runtimeClasspath`, et `build-back` compile avec `-x test`.

### Les deux seuils, et pourquoi ils ne mesurent pas la même chose

**Couverture (JaCoCo, `coverage-gate`)** : quelles lignes les tests
traversent-ils ? Seuil `COVERAGE_MIN` (90 %), appliqué en CI par
`scripts/ci/check_coverage.py`, et **aussi en local** par
`jacocoTestCoverageVerification` dans `back/build.gradle`, plus strict : 95 %
des lignes et 90 % des branches. Le doublon est voulu : un seuil qui ne se déclenche qu'en CI
se découvre toujours après le push. Côté front, l'équivalent est le bloc
`check.global` de `front/karma.conf.js`, actif avec `--code-coverage`.

**Mutation (PIT, `mutation-back`)** : les tests _vérifient_-ils quelque chose ?
Un test sans aucune assertion affiche 100 % de couverture. PIT modifie le
bytecode (inverse une condition, remplace un retour par `null`, supprime un
appel) puis relance les tests qui couvrent la ligne mutée. Si aucun ne devient
rouge, le mutant _survit_ : la ligne est exécutée mais rien ne l'observe.

```bash
cd back && ./gradlew pitest          # rapport dans build/reports/pitest/
MUTATION_MIN=80 ./gradlew pitest     # le seuil posé par variable, comme en CI
```

Le seuil du pipeline est **80** (`MUTATION_MIN` dans `.gitlab/ci/variables.yml`),
qui est aussi la valeur par défaut de `back/build.gradle`. Job séparé, parce que
PIT est nettement plus lent que `test-back` ; il est bloquant. Un **mutant
équivalent** (une mutation qui ne change rien) est absorbé par la marge du
seuil. Il en reste un, connu : la suppression de l'appel
`RepositoryRestConfigurer.super.configureRepositoryRestConfiguration(...)`, dont
l'implémentation par défaut est vide.

### Valeurs tenues

| Mesure                    | Valeur | Seuil CI             |
| ------------------------- | ------ | -------------------- |
| Back — tests JUnit        | 115    | 0 échec              |
| Back — lignes (JaCoCo)    | 97,4 % | 90 % (95 % en local) |
| Back — branches (JaCoCo)  | 100 %  | 90 % (local)         |
| Back — mutants tués (PIT) | 96 %   | 80 %                 |
| Front — tests Karma       | 112    | 0 échec              |
| Front — lignes            | 100 %  | 90 %                 |
| Front — branches          | 90,2 % | 80 %                 |

Tests et couverture mesurés le 6 octobre 2026 ; le score de mutation n'a pas été
remesuré à cette date.

Les seuils sont calés **sous** les valeurs tenues, avec assez de marge pour ne
pas se déclencher sur une ligne de plus, et assez peu pour qu'une vraie
régression se voie. `MicroCRMApplication` est la seule exclusion, côté
couverture comme côté mutation : sa méthode `main` ne contient que l'amorçage
Spring Boot.

---

## Récapitulatif des variables CI/CD à créer dans GitLab

| Variable             | Type              | Obligatoire   | Rôle                                   |
| -------------------- | ----------------- | ------------- | -------------------------------------- |
| `SONAR_HOST_URL`     | Variable          | pour Sonar    | URL du serveur SonarQube ou SonarCloud |
| `SONAR_TOKEN`        | Variable (masked) | pour Sonar    | Token d'analyse                        |
| `NVD_API_KEY`        | Variable (masked) | non           | Accélère Dependency-Check              |
| `STAGING_NAMESPACE`  | Variable          | pour déployer | Namespace de staging                   |
| `PROD_NAMESPACE`     | Variable          | pour déployer | Namespace de production                |
| `NOTIFY_WEBHOOK_URL` | Variable (masked) | non           | Canal d'équipe pour les notifications  |
| `CI_REGISTRY*`       | Automatiques      | —             | Fournies par GitLab, rien à faire      |

**Aucun kubeconfig en variable.** Les jobs de déploiement, comme les jobs
Terraform, joignent le cluster par le tunnel de l'agent GitLab pour Kubernetes,
qui injecte `KUBECONFIG` à l'exécution. Un kubeconfig de poste désigne le
serveur d'API en `127.0.0.1`, injoignable depuis un conteneur de job.

**Les deux namespaces sont obligatoires dès qu'on déploie.** Sans eux,
`kubectl apply -n ""` retomberait silencieusement sur le namespace `default` du
contexte. Le garde-fou `exige_namespace` de `.deploy_template` fait échouer le
job si l'une est vide.

**`NOTIFY_WEBHOOK_URL` est facultative**, et son absence ne fait rien échouer :
le message est alors écrit dans le journal du job. Voir [SCRIPTS.md](SCRIPTS.md).

Côté GitHub, un secret `GITLAB_TOKEN` (scope `write_repository`) alimente le
workflow de miroir vers GitLab.

**Rien à créer pour la base PostgreSQL des jobs de test.** Ses identifiants sont
écrits en clair dans `.gitlab/ci/templates.yml` (gabarit `.postgres_service`),
délibérément : la base naît et meurt avec le job, n'est joignable que depuis son
réseau, et ne contient que ce que les tests y écrivent. En faire une variable
masquée laisserait croire à un secret là où il n'y en a pas.

Le détail des variables de déploiement est dans [RELEASE.md](RELEASE.md) §6.
L'inventaire des valeurs externalisées est dans
[VARIABILISATION.md](VARIABILISATION.md).
