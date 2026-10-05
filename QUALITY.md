# Qualité, sécurité et supervision

Cinq outils sont branchés sur le cycle de vie de MicroCRM, et un sixième angle —
la supervision de l'application déployée — est couvert depuis par la stack ELK,
ses tableaux de bord et ses règles d'alerte (§6). Chacun voit ce que les
autres ne voient pas : un test unitaire ne détecte pas une CVE, un scan de CVE ne
détecte pas une mauvaise pratique de code, et aucun des deux ne dit si l'application
tient la charge.

| Outil                          | Question à laquelle il répond                                                  | Où il s'exécute            |
| ------------------------------ | ------------------------------------------------------------------------------ | -------------------------- |
| **SonarQube**                  | Le code respecte-t-il les bonnes pratiques ? Quelle est la dette ?             | stage `quality`            |
| **SpotBugs** (+ Find-Sec-Bugs) | Y a-t-il des bugs latents dans le bytecode ?                                   | stage `quality`            |
| **OWASP Dependency-Check**     | Mes dépendances Java portent-elles des CVE connues ?                           | stage `security`           |
| **Trivy**                      | Mes images Docker et mes fichiers portent-ils des CVE / secrets / misconfigs ? | stage `security`           |
| **k6**                         | L'API répond-elle correctement, et assez vite, sous charge ?                   | stage `perf`               |
| **Stack ELK**                  | Que raconte l'application une fois déployée ?                                  | hors CI, §6                |
| **JaCoCo + PIT**               | Les tests couvrent-ils le code, et vérifient-ils quelque chose ? (§7)          | stages `test` et `quality` |

S'y ajoutent, au stage `lint`, les contrôles de forme : **Checkstyle** et **Spotless**
côté back, **ESLint** et **Prettier** côté front, **ShellCheck** sur les scripts Bash.
Et avant même le push, les hooks **husky** (`lint-staged` et `commitlint`) filtrent en
local.

Le pipeline complet compte 10 stages : `lint` → `test` → `quality` → `security` →
`infra` → `build` → `package` → `perf` → `deploy` → `infra-apply`. Voir
[ARCHITECTURE.md](ARCHITECTURE.md) §4.

L'ordre n'est pas alphabétique : `infra` valide Terraform et Ansible **avant**
toute compilation — un plan cassé n'a pas besoin d'attendre Gradle pour être
signalé — et `infra-apply` est en dernier parce que ses jobs manuels
bloqueraient tout ce qui les suit.

> ⚠️ **Tous ces contrôles sont bloquants, sauf deux.**
>
> - **`k6-load`** (§5) : ses mesures varient d'une exécution à l'autre sur les
>   runners partagés, et un seuil dur y produirait des échecs sans rapport avec le
>   code.
> - **`spotbugs-back`** (§2) : `ignoreFailures = true` dans `back/build.gradle`.
>   Le job publie son rapport, il ne fait pas échouer le pipeline.
>
> Pour tout le reste, un échec arrête le pipeline : analyse Sonar qui n'a pas eu
> lieu, Quality Gate non franchie, CVE de score CVSS 7 ou plus dans
> les dépendances Java, misconfiguration ou CVE système relevée par Trivy, couverture
> ou score de mutation sous leur seuil, image qui ne répond pas au smoke test.

---

## 1. SonarQube — bonnes pratiques et dette technique

**Pourquoi.** C'est le filet de sécurité principal quand l'équipe manque d'expérience
Java : Sonar connaît les idiomes du langage et de Spring, et signale ce qu'une
relecture humaine peu expérimentée laisse passer (ressources non fermées, `equals`
sans `hashCode`, complexité cyclomatique, duplication, code mort). Il agrège aussi
la **couverture de tests** (JaCoCo côté back, LCOV côté front) et applique une
**Quality Gate** : la merge request est bloquée si le nouveau code passe sous le seuil.

**Mise en place.**

- Back : plugin Gradle `org.sonarqube` + `jacoco`, configurés dans `back/build.gradle`.
- Front : `front/sonar-project.properties`, analysé par `sonar-scanner-cli`.

**Serveur local.**

```shell
docker compose -f docker-compose.sonar.yml up -d
# http://localhost:9000 — admin / admin au premier démarrage
```

Générer ensuite un token dans l'UI (_My Account → Security_), puis :

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
eux : les deux jobs sont bloquants.

Le verdict de la Quality Gate est récupéré séparément par le job **`quality-gate`**,
qui appelle le script [`scripts/ci/quality_gate.py`](scripts/ci/quality_gate.py). Ce
script interroge l'API SonarCloud jusqu'à obtenir le résultat de l'analyse, puis sort
en `2` si la porte n'est pas franchie — en affichant les règles fautives. Il est lancé
deux fois, une par projet Sonar (back et front). Voir [SCRIPTS.md](SCRIPTS.md).

---

## 2. SpotBugs (+ Find-Sec-Bugs) — bugs potentiels

**Pourquoi.** SpotBugs analyse le **bytecode compilé**, pas le texte du source. Il
détecte donc des choses qu'aucun linter ne voit : déréférencement null sur un chemin
d'exécution particulier, comparaison de `String` avec `==`, flux non fermés, retours
ignorés. Le plugin **Find-Sec-Bugs** ajoute ~140 patterns de sécurité (injection SQL,
XSS, CORS permissif, cryptographie faible, désérialisation).

> Exemple concret sur ce projet : Find-Sec-Bugs remonte `PERMISSIVE_CORS` dans
> `SpringDataRestCustomization.java` — le `CorsRegistry` autorise toutes les origines.

**Utilisation locale.**

```shell
cd back
./gradlew spotbugsMain
open build/reports/spotbugs/spotbugsMain.html
```

**Configuration.** `back/config/spotbugs/exclude.xml` filtre les faux positifs connus
(entités JPA, classe `Application`). Le job CI est en `ignoreFailures = true` : les
findings sont publiés en artefact sans casser la pipeline. Passer ce flag à `false`
dans `back/build.gradle` quand l'équipe veut rendre le contrôle bloquant.

---

## 3. OWASP Dependency-Check — CVE des dépendances

**Pourquoi.** La majorité du code livré n'a pas été écrite par l'équipe : c'est celui
de Spring, Hibernate, Jackson, Tomcat. Dependency-Check confronte l'arbre de
dépendances Gradle à la base **NVD** et signale les CVE publiées. C'est le contrôle
qui aurait détecté Log4Shell.

**Utilisation locale.**

```shell
cd back
./gradlew dependencyCheckAnalyze
open build/reports/dependency-check/dependency-check-report.html
```

> La première exécution télécharge la base NVD (long). Une **clé API NVD** gratuite
> ([demande ici](https://nvd.nist.gov/developers/request-an-api-key)) réduit ce temps
> de ~10 min à ~1 min. La déclarer en variable d'environnement `NVD_API_KEY`
> (et en variable CI/CD masquée dans GitLab).

**Seuil.** `failBuildOnCVSS = 7.0` : la tâche échoue dès qu'une dépendance porte une
vulnérabilité de sévérité HIGH ou CRITICAL. Le job CI est bloquant : une CVE publiée
pendant la nuit arrête la livraison suivante, et c'est un arbitrage humain (mise à
jour, ou suppression justifiée et datée) qui la débloque.

**Exceptions.** À documenter et dater dans
`back/config/dependency-check/suppressions.xml`, jamais à ignorer silencieusement.

### ⚠️ Ce contrôle n'a rien lu pendant des semaines

Jusqu'au 2026-10-02, cette section pouvait écrire que `dependency-check-back`
« trouvait 0 vulnérabilité ». C'était vrai, et cela ne voulait rien dire :
**le scan n'analysait aucun jar.**

**La cause**, lue dans le journal `--info` du plugin et expliquée dans
`back/build.gradle` : le plugin écarte par défaut les configurations « de test »
(`skipTestGroups = true`) et les reconnaît à leur **nom**. Or le plugin Spring
Boot fait hériter `runtimeClasspath` de `testAndDevelopmentOnly`. La seule
configuration nommée par `scanConfigurations` était donc écartée, et le rapport
sortait avec une liste de dépendances vide. Le signe était visible : cinq
secondes de Gradle, un rapport XML de 1,4 Ko. C'est aussi l'explication de
l'écart resté ouvert depuis le 2026-09-14 — Trivy trouvait dans le jar des CVE
de Tomcat, puis de Jackson, que Dependency-Check ne signalait pas.

**Le correctif** est une ligne : `skipTestGroups = false`. Les dépendances de
test n'entrent pas pour autant, `scanConfigurations` ne nommant que
`runtimeClasspath`.

**Ce que le premier scan réel a trouvé** (2026-10-02, en local) : **82
dépendances analysées**, **13 CVE de score 7 ou plus** — 12 sur Spring Framework
6.2.19, 1 sur Log4j 2.24.3.

| Constat                                | Traitement                                                                                                                                      |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| CVE-2026-34479, Log4j 2.24.3           | **Corrigé** : Log4j forcé à 2.25.5 (`ext['log4j2.version']`)                                                                                    |
| 6 CVE de Spring WebFlux et RSocket     | **Exceptées** jusqu'au 2026-12-31 : ces modules ne sont pas sur le `runtimeClasspath`                                                           |
| 3 CVE de fonctions Spring MVC          | **Exceptées** jusqu'au 2026-12-31 : `XsltView`, Server-Sent Events et framework fonctionnel, que l'application n'utilise pas — aucun contrôleur |
| 3 CVE de SpEL et de liaison de données | **Exceptées** jusqu'au 2026-12-31, après analyse condition par condition contre les avis de Spring, et un contrôle par exécution sur staging    |

**Pourquoi des exceptions et non une montée de version.** La version corrigée
de la branche 6.2, la 6.2.20, n'est pas publiée sur Maven Central : les avis de
Spring la réservent au support payant. Le seul correctif en source ouverte est
Spring Framework 7, c'est-à-dire **Spring Boot 4** — une migration majeure, pas
un changement de numéro. Attendre ne lèverait donc rien. Les douze entrées,
leurs justifications et ce qui les ferait tomber sont dans
`back/config/dependency-check/suppressions.xml`, qui fait foi ; le processus
est décrit dans [AUDIT.md](AUDIT.md) §7.4.

**La leçon vaut pour tous les contrôles de cette page.** Une porte bloquante qui
ne lit rien ne se distingue pas, à l'œil, d'une porte qui n'a rien trouvé. Un
job vert se vérifie aussi par ce qu'il a regardé : sa durée, la taille de son
rapport, le nombre d'éléments analysés.

**L'état après traitement**, relu dans le rapport JSON du dernier scan local
(2026-10-02, 21 h 31) : 82 dépendances analysées, les 12 CVE exceptées
apparaissent comme supprimées, **aucune CVE de score 7 ou plus ne reste
ouverte**, et la tâche Gradle se termine en succès. **Le même résultat a été
obtenu en CI** depuis la fusion du 2026-10-03 : `dependency-check-back` est vert
dans les pipelines `#2909284076`, `#2912362926` et `#2913490784`, et son rapport
JSON, relu dans les artefacts, porte les mêmes 82 dépendances et les mêmes 12
CVE supprimées. Six CVE de score inférieur
à 7 (de 3,7 à 6,5) restent visibles dans le rapport : elles sont sous le seuil,
donc non bloquantes — et suivies par rien ([AUDIT.md](AUDIT.md) §7.4.5).

**Ce qui n'est pas vérifié.** Le scan corrigé n'a tourné que sur le poste : rien
de ce lot n'est encore passé dans un pipeline. Et les trois dernières exceptions
reposent sur une analyse, pas sur un correctif — elles tombent le jour où le
modèle reçoit un champ `BigDecimal`, une liste auto-peuplée, ou que le
compilateur SpEL est activé.

> ⚠️ Il n'existe **pas** d'équivalent côté front aujourd'hui : aucun job ne lance
> `npm audit`. Les dépendances npm ne sont couvertes que par `trivy-fs`, qui lit le
> `package-lock.json`. C'est une piste d'amélioration identifiée, pas un contrôle en
> place.

---

## 4. Trivy — CVE des images Docker, secrets et misconfigurations

**Pourquoi.** Dependency-Check ne voit que les dépendances Java. L'image livrée
contient aussi un OS (Alpine), une JRE, un serveur web (Caddy) — chacun avec ses
propres CVE. Trivy scanne les **couches système** de l'image finale. Il détecte en
prime les **secrets commités** et les **mauvaises configurations** de Dockerfile.

> Exemple concret sur ce projet : le scan du dépôt relève des misconfigurations HIGH
> sur les manifestes Kubernetes, le RBAC de l'agent GitLab et le Dockerfile du back.
> Toutes sont justifiées et bornées à leur fichier dans `.trivyignore.yaml`
> (7 entrées, revue au 2026-12-31). Les deux défauts que cette
> section citait auparavant — image front en `root`, CVE ouvertes sur `@angular/*` —
> sont fermés depuis la montée d'Angular 20 et celle des images du 2026-09-19.

**Deux jobs, deux portées.**

- Le job **`trivy-fs`** (stage `security`, rapide) scanne le dépôt : dépendances
  déclarées, secrets oubliés, misconfigurations de Dockerfile.
- Le **scan des images** n'est pas un job séparé : il est lancé dans
  `package-back` et `package-front`, **entre** la construction de l'image et son
  envoi au registry (`build_and_push.sh --scan`).

**Les deux sont bloquants** depuis le 2026-09-19, sur `HIGH,CRITICAL`. Depuis le
2026-10-02 ils ne passent plus par un `--exit-code 1` écrit en dur dans le
pipeline, mais par `scripts/ci/trivy_scan.sh`, qui fait deux passages : un
**relevé** en JSON, sans porte, puis la **porte**, au format tableau. Son code
de sortie distingue un constat d'une panne — `2` quand la porte est fermée, `1`
quand le scan n'a pas pu avoir lieu ; le job échoue dans les deux cas.
`trivy-fs` passe en plus `--ignorefile .trivyignore.yaml` : Trivy ne lit que
`.trivyignore` par défaut, et sans ce drapeau les exclusions justifiées ne
s'appliquent pas.

**Les rapports sont publiés en artefacts**, que le job réussisse ou non
(`when: always`, une semaine) :

| Job             | Artefacts                                                         |
| --------------- | ----------------------------------------------------------------- |
| `trivy-fs`      | `reports/trivy-fs.json`, `reports/trivy-fs.txt`                   |
| `package-back`  | `reports/trivy-image-back.json`, `reports/trivy-image-back.txt`   |
| `package-front` | `reports/trivy-image-front.json`, `reports/trivy-image-front.txt` |

Ils sont **filtrés comme la porte** — HIGH et CRITICAL seulement, exclusions
appliquées : ils décrivent ce que la porte a vu, pas tout ce que Trivy sait.
`scripts/ci/collect_security.py` sait les indexer pour le tableau de bord
« sécurité » ([SCRIPTS.md](SCRIPTS.md)).

**Pourquoi le scan d'image a été déplacé avant le push.** Il était jusque-là une
ligne placée _après_ `build_and_push.sh`. L'image d'un job rouge était donc déjà
au registry sous son SHA, et la promotion par tag ne demande que l'existence de
ce tag : un tag de version posé sur ce commit aurait promu une image que Trivy
venait de refuser. Le cas s'est présenté — `back:5bf1d6a2` est au registry avec
5 CVE HIGH de Jackson. Un test de `run_tests.sh` vérifie désormais l'ordre.

**Où en sont les scans.** Le scan du dépôt sort à 0 constat une fois les
exclusions appliquées (rejoué le 2026-10-02). La dernière image du back publiée
par la CI, `back:5bf1d6a2`, porte 5 CVE HIGH de `jackson-core` et
`jackson-databind` 2.21.4 : c'est ce qui a arrêté `package-back` sur le dernier
pipeline de `develop` (les deux pipelines précédents ont échoué pour d'autres
raisons — [MONITORING.md](MONITORING.md) §10.4). Jackson est forcé à 2.21.7
depuis la fusion du 2026-10-03. **Les images corrigées sont publiées** : les
rapports Trivy de `package-back` et `package-front`, relus dans les artefacts,
portent 0 HIGH ou CRITICAL sur `back:5296658a`, `front:5296658a`,
`back:08a216b0` et `front:08a216b0` — ces deux dernières sont les images `1.0.1`
en production depuis le 2026-10-05. `back:5bf1d6a2` reste au registry, mais
n'est déployée nulle part.

**Utilisation locale** (sans installer Trivy) :

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

Les exceptions assumées se déclarent dans `.trivyignore.yaml` — une entrée par
identifiant **et** par chemin, avec sa justification et sa date de revue.

---

## 5. k6 — tests de performance

**Pourquoi.** Tous les contrôles précédents lisent du code ou des dépendances : aucun
ne lance l'application. On peut donc avoir un pipeline entièrement vert et livrer une
API qui s'écroule à dix utilisateurs, parce qu'une requête mal indexée est passée
inaperçue. k6 comble ce trou : il joue de vraies requêtes HTTP sur l'application
démarrée, et compare les temps de réponse à un budget écrit dans le dépôt.

J'ai choisi k6 plutôt que JMeter parce que les scénarios s'écrivent en JavaScript
(donc relisibles en revue de code, versionnés à côté du reste), qu'il s'exécute dans
un simple conteneur sans installation, et qu'il sait sortir en erreur tout seul quand
un seuil est dépassé — ce qui en fait un gate de CI et pas juste un rapport à lire.

**Ce qui est testé.** Le back en entier, à travers son API REST : liste des personnes,
fiche d'une personne, organisations liées, liste des organisations, recherche par
email, puis création et suppression d'une fiche. Le point important est que **chaque
réponse est vérifiée fonctionnellement** (statut HTTP _et_ contenu attendu) : un
serveur qui renvoie « 500 » en 3 ms est très rapide et totalement cassé, et sans ces
vérifications un test de charge le déclarerait excellent.

### Les trois scénarios

| Fichier              | Ce qu'il fait                                                                  | Rôle                        |
| -------------------- | ------------------------------------------------------------------------------ | --------------------------- |
| `tests/k6/smoke.js`  | 1 utilisateur, 5 parcours complets (lecture + écriture)                        | « est-ce que ça marche ? »  |
| `tests/k6/load.js`   | Charge nominale : 10 utilisateurs en lecture + 2 écritures/s pendant le palier | garde-fou des temps réponse |
| `tests/k6/stress.js` | Montée par paliers jusqu'à 50 utilisateurs, sans pause                         | trouver le point de rupture |

`load.js` fait tourner deux populations **en même temps**, ce qui est plus fidèle
qu'un parcours moyen unique : un CRM lit beaucoup plus qu'il n'écrit. Les lectures
montent progressivement avec une pause entre deux clics ; les écritures partent à un
rythme fixe (2/s) une fois le palier atteint. Un rythme fixe est volontaire : si l'API
ralentit, la charge d'écriture ne baisse pas toute seule, et le problème se voit.

### Le budget de performance

Les seuils vivent dans `tests/k6/lib/config.js` et sont surchargeables par variable
d'environnement, ce qui est pratique pour explorer en local. **Convention d'équipe :
on ne définit pas de variable de seuil dans GitLab** — un gate dont on desserre le
seuil depuis l'interface n'est plus un gate. Les variables CI/CD servent à régler la
charge (`K6_LOAD_VUS`, `K6_LOAD_DURATION`...), pas le budget.

| Seuil                             | Valeur par défaut | Variable            |
| --------------------------------- | ----------------- | ------------------- |
| p95 des lectures                  | 500 ms            | `K6_P95_READ_MS`    |
| p95 des écritures                 | 800 ms            | `K6_P95_WRITE_MS`   |
| Taux de requêtes en erreur        | < 1 %             | `K6_ERROR_RATE_MAX` |
| p95 du smoke (application froide) | 1500 ms           | `K6_P95_SMOKE_MS`   |

Deux choix à souligner. D'abord des **percentiles et pas des moyennes** : une moyenne
correcte peut très bien cacher 5 % d'utilisateurs qui attendent trois secondes.
Ensuite **un seuil par endpoint** plutôt qu'un seuil global : c'est ce qui permet de
dire « c'est la recherche par email qui décroche » au lieu de « c'est lent ».

Le budget du smoke est volontairement large : ce scénario tourne juste après le
démarrage du conteneur, quand la JVM n'a encore rien optimisé. Ce sont les seuils de
`load.js` qui font foi.

### Dans la CI

Le stage `perf` s'exécute **après `package`**, et c'est délibéré : GitLab démarre
l'image Docker qui vient d'être construite comme un **service** (accessible sur
`http://back:8080`), et k6 tourne dans le conteneur du job pour l'interroger. On
mesure donc l'artefact qui partira réellement en production, et pas une compilation
locale qui pourrait en différer.

Le job tient en une ligne (`k6 run tests/k6/smoke.js`) : c'est GitLab qui gère le
cycle de vie du conteneur applicatif. Pas de Docker-in-Docker, pas de conteneur à
démarrer et nettoyer soi-même.

| Job         | Scénario    | Bloquant ?                  |
| ----------- | ----------- | --------------------------- |
| `k6-smoke`  | `smoke.js`  | **oui**                     |
| `k6-load`   | `load.js`   | non (`allow_failure: true`) |
| `k6-stress` | `stress.js` | **oui**, lancé sur demande  |

`k6-load` n'est pas bloquant pour une raison précise : les runners GitLab partagés
sont mutualisés, leurs mesures varient d'une exécution à l'autre, et un seuil dur y
produirait des échecs aléatoires sans rapport avec le code — le meilleur moyen de
faire perdre confiance dans un gate. Sur un runner dédié, il suffit de passer
`allow_failure` à `false` pour en faire un vrai gate. `k6-stress`, lui, cherche
volontairement la rupture : il n'a rien à faire dans un pipeline automatique. Il ne
tourne que si le pipeline est lancé à la main (« New pipeline ») avec la variable
`K6_STRESS=true`. Prérequis hors dépôt : dans Settings → CI/CD → Variables,
« Minimum role to use pipeline variables » doit être réglé sur Developer ; sur
« No one allowed », le défaut des projets récents, le formulaire n'affiche pas la
section Variables. Il n'est pas en `when: manual` : sans `allow_failure`, un job
manuel bloquerait le pipeline enfant, et le déploiement derrière lui. Conséquence à
connaître : s'il franchit ses seuils de rupture, ce pipeline-là passe au rouge.

L'attente du démarrage de l'application est gérée par les scénarios eux-mêmes
(fonction `setup`, jusqu'à `K6_READY_TIMEOUT_S` secondes), et non par un `sleep` au
jugé dans le `.gitlab-ci.yml`. Ces requêtes d'attente sont marquées comme normales
quel que soit leur statut, pour ne pas fausser le taux d'erreur du test.

**Pas de rapport JSON en artefact**, et c'est une conséquence assumée du choix
ci-dessus : l'image `grafana/k6` s'exécute avec un utilisateur non-root, qui peut lire
le dépôt cloné mais pas y écrire. Le résumé complet de k6 (seuils, percentiles par
endpoint, checks) reste lisible dans le **log du job**. Pour un rapport exploitable,
`scripts/tests/run_k6.sh` écrit un JSON en local.

Deux points utiles au débogage :

- Pour voir les logs de l'application quand un job échoue, définir la variable CI/CD
  `CI_DEBUG_SERVICES` à `"true"` : GitLab affiche alors la sortie des services.
- `back/Dockerfile` déclare `EXPOSE 4200` alors que l'application écoute sur `8080`.
  La sonde de service GitLab affiche donc un avertissement du type « service probably
  didn't start properly ». Sans conséquence ici — c'est l'attente de `setup` qui fait
  foi — mais corriger cet `EXPOSE` supprimerait le message.

> L'image k6 est **figée** (`grafana/k6:2.1.0`) et non en `latest`, contrairement aux
> autres outils : d'une version à l'autre les mesures ne seraient plus comparables.

### Utilisation locale

```shell
# Démarrer l'API dans un terminal
cd back && ./gradlew build && java -jar build/libs/microcrm-0.0.1-SNAPSHOT.jar

# Puis, dans un autre terminal
scripts/tests/run_k6.sh                          # smoke (défaut)
scripts/tests/run_k6.sh --scenario load
K6_LOAD_VUS=25 scripts/tests/run_k6.sh -s load   # charge plus forte

# Sans installer k6, en reproduisant exactement ce que fait la CI
docker run --rm --network host -v "$PWD:/work" -w /work \
  -e K6_BASE_URL=http://localhost:8080 \
  grafana/k6:2.1.0 run tests/k6/smoke.js
```

Le script `scripts/tests/run_k6.sh` n'est qu'un raccourci de confort : toute la
logique (charge, seuils, parcours) est dans les fichiers `tests/k6/*.js`, de sorte que
la commande locale et le job CI mesurent exactement la même chose. Voir
[SCRIPTS.md](SCRIPTS.md) pour ses options et ses codes de sortie.

> **Ce que ces tests ont déjà trouvé.** Dès la première exécution, le smoke a signalé
> que `POST /persons` renvoyait un corps vide. Ce n'était pas un bug de l'API :
> Spring Data REST ne renvoie la ressource créée que si le client envoie un en-tête
> `Accept`. Le front Angular l'envoie, k6 non — le scénario a donc été corrigé pour
> se comporter comme le vrai client. C'est exactement le genre d'écart qu'un test qui
> ne vérifierait que le code HTTP aurait laissé passer.

### Limites assumées

- Les mesures dépendent de la machine : elles servent à détecter une **régression**
  entre deux exécutions comparables, pas à annoncer une capacité absolue.
- La base est une HSQLDB en mémoire, plus rapide qu'une vraie base réseau. Les
  chiffres sont donc optimistes en valeur absolue. C'est propre à ces jobs : k6
  attaque l'**image livrée**, démarrée en service sans variable
  `SPRING_DATASOURCE_*`, donc sur son moteur par défaut. La suite de tests du
  back, elle, s'exécute désormais sur un PostgreSQL réel (§7) — les deux jobs ne
  parlent plus à la même base, et c'est voulu : ici on mesure une tendance, là on
  vérifie un comportement.
- Le front n'est pas testé en charge (ce serait le rôle d'un Lighthouse CI) : seul
  le back l'est, parce que c'est lui qui porte le risque de saturation.

---

## 6. Supervision de l'application déployée — **implémenté**

> Cette section annonçait une amélioration prévue. Elle est faite, par étapes,
> et ce qui suit décrit ce qui existe réellement dans le dépôt au 2026-10-05.

**Le manque de départ.** Les quatre outils précédents agissent tous **avant** le
déploiement. Une fois l'application en marche, plus rien ne disait si elle répondait,
si sa base était joignable, ni ce qu'elle racontait.

**Ce qui a été fait, et où c'est décrit.**

| Volet                                   | État                        | Détail                                                                                                                                                                                                                                                                                                                                                                        |
| --------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sondes de santé                         | fait                        | Actuator est en dépendance, et les trois sondes (`startup`, `liveness`, `readiness`) sont posées sur les deux Deployments — [K8S.md](K8S.md) §5. Vérifiées sous kubelet en §14.3                                                                                                                                                                                              |
| Centralisation des logs                 | fait                        | Elasticsearch, Kibana et Filebeat sur le cluster local ; les logs du back sont en JSON ECS et arrivent décodés. **Staging seulement** : Filebeat ne collecte pas la production — [MONITORING.md](MONITORING.md)                                                                                                                                                               |
| Tableaux de bord                        | fait                        | Cinq tableaux de bord versionnés dans `k8s/elk/dashboards/` : supervision, DORA, sécurité, disponibilité, suivi des alertes — [MONITORING.md](MONITORING.md) §8                                                                                                                                                                                                               |
| Alerting                                | fait, **sans notification** | Huit règles Kibana versionnées (disponibilité, performance, sécurité), installées par `scripts/monitoring/install_alerting.py`, toutes déclenchées une fois le 2026-10-02. Elles écrivent dans l'index `microcrm-alerts` et dans le journal de Kibana ; **rien ne sort de Kibana**, les connecteurs webhook exigeant une licence payante — [MONITORING.md](MONITORING.md) §11 |
| Latence, débit et taux d'échec de l'API | **fait, sans recul**        | Traces OpenTelemetry vers Elastic APM, éprouvées d'abord depuis un conteneur lancé sur le poste, en service depuis le 2026-10-05 : les pods de staging et de production en émettent. Aucune latence en service relevée à ce jour — [MONITORING.md](MONITORING.md) §10                                                                                                         |
| Métriques de ressources (CPU, mémoire)  | **absent**                  | Ni Prometheus ni `metrics-server` sur le cluster ; les métriques de la JVM que l'agent pourrait envoyer sont coupées. Les `resources` des Deployments restent des estimations                                                                                                                                                                                                 |

Ce qui suit dans cette section décrivait l'ajout d'Actuator ; c'est fait, et le
détail des sondes est désormais dans [K8S.md](K8S.md) §5. Conservé ici pour le
raisonnement sur l'exposition minimale des endpoints, qui reste valable.

Conséquence concrète sur le pipeline : le job `deploy-staging` s'appuie uniquement sur
`kubectl rollout status`, qui vérifie que les pods démarrent — pas que l'application
fonctionne.

**Ce qu'il faudrait ajouter** (estimé à moins d'une heure) :

1. La dépendance `org.springframework.boot:spring-boot-starter-actuator` dans
   `back/build.gradle`.
2. Dans `application.properties`, n'exposer que le strict nécessaire —
   `management.endpoints.web.exposure.include=health,info` — car exposer `env`,
   `beans` ou `heapdump` en production divulguerait la configuration interne.
3. Un `HEALTHCHECK` dans `back/Dockerfile` pointant sur
   `/actuator/health/readiness`.
4. Des sondes `livenessProbe` et `readinessProbe` dans le manifeste Kubernetes du
   back, pour que le rollout échoue vraiment si l'application ne répond pas — et
   déclenche donc le rollback automatique de `deploy.sh`.

> Pour aller plus loin : `io.micrometer:micrometer-registry-prometheus` exposerait
> `/actuator/prometheus`, scrapable par Prometheus/Grafana. C'est ce qui manque
> encore : les traces donnent la latence de l'API, pas la consommation des pods.

---

## 7. Les tests — couverture, et force des assertions

### Ce que chaque niveau vérifie

| Niveau                     | Où                                                                                                                   | Ce qu'il attrape                                                                                                    |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Unitaires (back)           | `PersonTest`, `OrganizationTest`, `InitialDataFixtureTest`, `SpringDataRestCustomizationTest`                        | Logique des entités et de la configuration, sans base ni contexte Spring. Quelques millisecondes.                   |
| Intégration JPA            | `*RepositoryIntegrationTest`, `PersonDeletionIntegrationTest`                                                        | Ce que fait réellement Hibernate : cascades, table de jointure, contraintes, hook `@PreRemove`.                     |
| Contrat HTTP               | `PersonRestApiTest`, `PersonRestLifecycleTest`, `OrganizationRestApiTest`, `CorsPolicyTest`, `ActuatorEndpointsTest` | Les endpoints que Spring Data REST **génère** — donc ceux qu'aucune ligne du dépôt ne décrit.                       |
| Configuration variabilisée | `CorsAllowedOriginsOverrideTest`                                                                                     | Que la surcharge par variable d'environnement est bien lue, et que le défaut de développement cesse de s'appliquer. |
| Unitaires (front)          | `*.service.spec.ts`, `*.component.spec.ts`, `config.spec.ts`                                                         | Les requêtes réellement émises (URL, méthode, en-têtes) et l'enchaînement des appels.                               |
| Scripts                    | `scripts/tests/run_tests.sh`                                                                                         | Les scripts d'automatisation, avec `kubectl`, `docker`, `terraform`… remplacés par des stubs.                       |
| Charge                     | `tests/k6/`                                                                                                          | Le comportement sous charge, budget de performance à l'appui (§5).                                                  |

Le niveau « contrat HTTP » mérite d'être souligné : l'API n'a **aucun contrôleur**.
Les URL, les codes de retour et la sémantique des liens d'association viennent
entièrement de Spring Data REST. Ni le compilateur, ni Checkstyle, ni SpotBugs
ne voient ces endpoints. Les tests sont leur seule description exécutable — et
c'est en les écrivant qu'ont été trouvés les trois HTTP 500 et les deux appels
sans effet corrigés au passage.

### Sur quel moteur de base ces tests s'exécutent

**En CI : un PostgreSQL réel**, démarré comme service du job (`postgres:16-alpine`,
version figée dans le bloc `variables:` du pipeline au même titre que les autres
images). **En local : HSQLDB en mémoire**, sans rien à installer.

Ce n'est pas une inconséquence, c'est la seule répartition qui tienne les deux
exigences à la fois : `cd back && ./gradlew test` doit rester lançable sur un
poste nu, et le code doit rencontrer le moteur de production avant la production.
Le schéma de MicroCRM n'est écrit nulle part — Hibernate le déduit des entités —
donc personne ne le relit avant qu'il n'existe. Or ce qu'un moteur tolère,
l'autre le refuse : types rapprochés, casse des identifiants, ordre de tri sans
`ORDER BY`, moment où une contrainte est vérifiée. Une suite verte sur HSQLDB ne
dit rien de PostgreSQL.

La bascule ne passe par aucun profil Spring ni fichier de configuration, mais par
les trois variables standard `SPRING_DATASOURCE_URL`,
`SPRING_DATASOURCE_USERNAME` et `SPRING_DATASOURCE_PASSWORD` : absentes, HSQLDB ;
présentes, PostgreSQL. Un fichier `application-postgres.properties` aurait eu le
même effet en CI, mais aurait ajouté une configuration à maintenir en double et
un profil à ne pas oublier d'activer. Là, il n'y a rien à oublier : c'est
l'environnement qui décide, et le même mécanisme sert au déploiement.
[README.md](README.md) donne la commande pour reproduire l'exécution CI sur un
poste.

Deux jobs reçoivent ce service, `test-back` et `mutation-back` :

| Job             | Pourquoi le service                                                                                                                                                                                                                                                                      |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test-back`     | C'est lui qui exécute la suite, et dont le rapport JaCoCo alimente tout le stage `quality`.                                                                                                                                                                                              |
| `mutation-back` | PIT rejoue la suite **une fois par mutant** : sans le service il la rejouerait sur HSQLDB, et publierait un score de mutation vert mesuré sur un moteur qu'on ne déploie pas. Le job y perd en durée — il porte pour cela un `timeout` explicite — et y gagne de mesurer ce qu'on livre. |

Les autres jobs qui touchent au back ne relancent aucun test et n'ont donc pas
besoin de base : `sonar-back` lit les classes compilées et le XML JaCoCo repris
en artefact (la tâche `sonar` du plugin Gradle ne déclare qu'un `mustRunAfter`
sur `test`, jamais un `dependsOn`), `coverage-gate` lit ce même XML,
`spotbugs-back` analyse du bytecode, `dependency-check-back` résout le
`runtimeClasspath`, et `build-back` compile avec `-x test`.

### Les deux seuils, et pourquoi ils ne mesurent pas la même chose

**Couverture (JaCoCo, `coverage-gate`)** — quelles lignes les tests traversent-ils ?
Seuil `COVERAGE_MIN` (90 %), appliqué en CI par `scripts/ci/check_coverage.py`, et
**aussi en local** par `jacocoTestCoverageVerification` dans `back/build.gradle`, qui
ajoute un seuil de branches à 90 %. Le doublon est voulu : un seuil qui ne se
déclenche qu'en CI se découvre toujours après le push. Côté front, l'équivalent est
le bloc `check.global` de `front/karma.conf.js`, actif avec `--code-coverage`.

**Mutation (PIT, `mutation-back`)** — les tests _vérifient_-ils quelque chose ?
C'est la question que la couverture ne sait pas poser : un test sans aucune
assertion affiche 100 % de couverture. PIT modifie le bytecode — inverse une
condition, remplace un retour par `null`, supprime un appel — puis relance les
tests qui couvrent la ligne mutée. Si aucun ne devient rouge, le mutant _survit_ :
la ligne est exécutée mais rien ne l'observe.

```bash
cd back && ./gradlew pitest          # rapport dans build/reports/pitest/
MUTATION_MIN=80 ./gradlew pitest     # le seuil posé par variable, comme en CI
```

Le seuil du pipeline est **80** (`MUTATION_MIN` dans `.gitlab/ci/variables.yml`),
et c'est aussi la valeur par défaut de `back/build.gradle` quand la variable est
absente. La surcharger sert à essayer un seuil plus strict en local.

Job séparé, parce que PIT relance la suite une fois par mutant et qu'il est
nettement plus lent que `test-back`. Il est bloquant : sous `MUTATION_MIN`, le
pipeline s'arrête. Un **mutant équivalent** — une mutation qui ne change réellement
rien — est absorbé par la marge du seuil. Il en reste un, connu et documenté : la suppression de l'appel
`RepositoryRestConfigurer.super.configureRepositoryRestConfiguration(...)`, dont
l'implémentation par défaut est vide. Aucun test ne peut le tuer.

### Où en sont les chiffres

| Mesure                    | Valeur | Seuil |
| ------------------------- | ------ | ----- |
| Back — lignes (JaCoCo)    | 97 %   | 90 %  |
| Back — branches (JaCoCo)  | 100 %  | 90 %  |
| Back — mutants tués (PIT) | 96 %   | 80 %  |
| Front — lignes            | 100 %  | 90 %  |
| Front — branches          | 90 %   | 80 %  |

Les seuils sont calés **sous** les valeurs tenues, avec assez de marge pour ne pas
se déclencher sur une ligne de plus, et assez peu pour qu'une vraie régression se
voie. Un seuil qu'on abaisse à la première gêne ne protège plus rien.

`MicroCRMApplication` est la seule exclusion, côté couverture comme côté mutation :
sa méthode `main` ne contient que l'amorçage Spring Boot. L'exclusion est nommée,
pas un motif large qui absorberait du code métier au passage.

---

## Récapitulatif des variables CI/CD à créer dans GitLab

| Variable             | Type              | Obligatoire   | Rôle                                  |
| -------------------- | ----------------- | ------------- | ------------------------------------- |
| `SONAR_HOST_URL`     | Variable          | pour Sonar    | URL du serveur SonarQube              |
| `SONAR_TOKEN`        | Variable (masked) | pour Sonar    | Token d'analyse                       |
| `NVD_API_KEY`        | Variable (masked) | non           | Accélère Dependency-Check             |
| `STAGING_NAMESPACE`  | Variable          | pour déployer | Namespace de staging                  |
| `PROD_NAMESPACE`     | Variable          | pour déployer | Namespace de production               |
| `NOTIFY_WEBHOOK_URL` | Variable (masked) | non           | Canal d'équipe pour les notifications |
| `CI_REGISTRY*`       | Automatiques      | —             | Fournies par GitLab, rien à faire     |

**`KUBE_CONFIG` a disparu de cette liste le 2026-09-23**, et ce n'est pas un
oubli. Les jobs de déploiement passaient par un kubeconfig stocké en variable ;
ils passent désormais par le tunnel de l'agent Kubernetes, comme les jobs
Terraform. Un kubeconfig de poste désigne le serveur d'API en `127.0.0.1`, ce
qui est structurellement injoignable depuis un conteneur de job. Si la variable
existe encore dans votre projet, elle ne sert plus à rien et peut être
supprimée.

**Les deux namespaces sont OBLIGATOIRES dès qu'on déploie.** Sans eux,
`kubectl apply -n ""` retombe silencieusement sur le namespace `default` du
contexte : c'est arrivé, l'application a été déployée au mauvais endroit sans
qu'aucune ligne du journal ne le signale. Le garde-fou `exige_namespace` de
`.deploy_template` fait désormais échouer le job, mais la variable reste à
créer.

**`NOTIFY_WEBHOOK_URL` est facultative**, et son absence ne fait rien échouer :
le message est alors simplement écrit dans le journal du job. Voir
[SCRIPTS.md](SCRIPTS.md) pour les deux partis pris de `notify.py`.

Côté GitHub, un secret `GITLAB_TOKEN` (scope `write_repository`) est nécessaire au
workflow de miroir vers GitLab.

**Rien à créer pour la base PostgreSQL des jobs de test.** Ses identifiants sont
écrits en clair dans `.gitlab-ci.yml`, et c'est délibéré : la base naît et meurt
avec le job, n'est joignable que depuis son réseau, et ne contient que ce que les
tests y écrivent. En faire une variable masquée laisserait croire à un secret
là où il n'y en a pas — et le vrai risque des secrets est qu'on cesse de
distinguer ceux qui en sont.

Sans `SONAR_TOKEN`, les jobs Sonar échouent, et le pipeline avec eux : ils sont
bloquants. Le détail des variables de déploiement est dans
[RELEASE.md](RELEASE.md) §6.

L'inventaire des valeurs encore codées en dur dans le dépôt, et le plan pour les
externaliser, sont dans [VARIABILISATION.md](VARIABILISATION.md).
