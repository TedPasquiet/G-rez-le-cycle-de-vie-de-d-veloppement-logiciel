# Qualité, sécurité et supervision

Quatre outils sont branchés sur le cycle de vie de MicroCRM, et un cinquième angle —
la supervision de l'application déployée — reste à couvrir. Chacun voit ce que les
autres ne voient pas : un test unitaire ne détecte pas une CVE, et un scan de CVE ne
détecte pas une mauvaise pratique de code.

| Outil                          | Question à laquelle il répond                                                  | Où il s'exécute  |
| ------------------------------ | ------------------------------------------------------------------------------ | ---------------- |
| **SonarQube**                  | Le code respecte-t-il les bonnes pratiques ? Quelle est la dette ?             | stage `quality`  |
| **SpotBugs** (+ Find-Sec-Bugs) | Y a-t-il des bugs latents dans le bytecode ?                                   | stage `quality`  |
| **OWASP Dependency-Check**     | Mes dépendances Java portent-elles des CVE connues ?                           | stage `security` |
| **Trivy**                      | Mes images Docker et mes fichiers portent-ils des CVE / secrets / misconfigs ? | stage `security` |
| _Supervision applicative_      | _L'application déployée est-elle en bonne santé ?_                             | _non implémenté_ |

S'y ajoutent, au stage `lint`, les contrôles de forme : **Checkstyle** et **Spotless**
côté back, **ESLint** et **Prettier** côté front, **ShellCheck** sur les scripts Bash.
Et avant même le push, les hooks **husky** (`lint-staged` et `commitlint`) filtrent en
local.

Le pipeline complet compte 7 stages : `lint` → `test` → `quality` → `security` →
`build` → `package` → `deploy`. Voir [ARCHITECTURE.md](ARCHITECTURE.md) §4.

> ⚠️ **Aucun de ces contrôles n'est bloquant aujourd'hui.** Les sept jobs de qualité
> et de sécurité (`sonar-back`, `sonar-front`, `spotbugs-back`, `coverage-gate`,
> `quality-gate`, `dependency-check-back`, `trivy-fs`) sont en `allow_failure: true`,
> et les scans Trivy tournent en `--exit-code 0`. Ils **informent** sans jamais
> arrêter le pipeline. C'est un choix de démarrage assumé, à lever contrôle par
> contrôle une fois le processus de traitement des vulnérabilités rodé.

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
`SONAR_HOST_URL` et `SONAR_TOKEN` ; sans elles ils échouent, mais comme ils sont en
`allow_failure: true`, le pipeline reste vert et l'échec est simplement toléré.

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
vulnérabilité de sévérité HIGH ou CRITICAL. Le job CI est en `allow_failure: true`
pour qu'une CVE publiée pendant la nuit ne bloque pas une livraison sans arbitrage
humain — à retirer une fois le processus de traitement rodé.

**Faux positifs.** À documenter et dater dans
`back/config/dependency-check/suppressions.xml`, jamais à ignorer silencieusement.

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

> Exemples concrets sur ce projet : `front/Dockerfile` tourne en `root` (DS-0002),
> et plusieurs CVE HIGH sont ouvertes sur les paquets `@angular/*`.

**Deux jobs, deux portées.**

- Le job **`trivy-fs`** (stage `security`, rapide) scanne le dépôt : dépendances
  déclarées, secrets oubliés, misconfigurations de Dockerfile.
- Le **scan des images** n'est pas un job séparé : il est lancé en fin de
  `package-back` et `package-front`, juste après la construction de l'image, via un
  `docker run aquasec/trivy image`.

Les deux tournent aujourd'hui avec `--exit-code 0` : ils **publient** les
vulnérabilités sans jamais bloquer le pipeline. Le script
[`scripts/ci/build_and_push.sh`](scripts/ci/build_and_push.sh) sait pourtant refuser
de pousser une image porteuse d'une CVE CRITICAL (option `--scan`, code de sortie 2) —
il suffirait d'activer cette option dans les jobs `package-*` pour rendre le contrôle
bloquant.

**Utilisation locale** (sans installer Trivy) :

```shell
# Scan du dépôt
docker run --rm -v "$PWD:/scan" aquasec/trivy:latest \
  fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
  --skip-dirs front/node_modules --skip-dirs back/build /scan

# Scan d'une image construite
docker compose build
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest \
  image --severity HIGH,CRITICAL --ignore-unfixed back-p6
```

Les exceptions assumées se déclarent dans `.trivyignore`.

---

## 5. Supervision de l'application déployée — **non implémenté**

> Cette section décrit une **amélioration prévue**, pas un contrôle en place.
> Rien de ce qui suit n'existe aujourd'hui dans le dépôt.

**Le manque.** Les quatre outils précédents agissent tous **avant** le déploiement.
Une fois l'application en production, plus rien ne dit si elle répond, si sa base est
joignable, ou quelle est sa consommation mémoire. C'est aussi ce qui manque à
Kubernetes pour savoir quand router du trafic vers un pod : sans sonde, le cluster
considère un conteneur démarré comme prêt, même si l'application est encore en train
de charger.

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
> `/actuator/prometheus`, scrapable par Prometheus/Grafana.

---

## Récapitulatif des variables CI/CD à créer dans GitLab

| Variable            | Obligatoire       | Rôle              |
| ------------------- | ----------------- | ----------------- |
| Variable            | Type              | Obligatoire       | Rôle                                        |
| ------------------- | ----------------- | ----------------- | ------------------------------------------- |
| `SONAR_HOST_URL`    | Variable          | pour Sonar        | URL du serveur SonarQube                    |
| `SONAR_TOKEN`       | Variable (masked) | pour Sonar        | Token d'analyse                             |
| `NVD_API_KEY`       | Variable (masked) | non               | Accélère Dependency-Check                   |
| `KUBE_CONFIG`       | **File**          | pour déployer     | Connexion au cluster Kubernetes             |
| `STAGING_NAMESPACE` | Variable          | pour déployer     | Namespace de staging                        |
| `PROD_NAMESPACE`    | Variable          | pour déployer     | Namespace de production                     |
| `CI_REGISTRY*`      | Automatiques      | —                 | Fournies par GitLab, rien à faire           |

Côté GitHub, un secret `GITLAB_TOKEN` (scope `write_repository`) est nécessaire au
workflow de miroir vers GitLab.

Sans `SONAR_TOKEN`, les jobs Sonar échouent mais le pipeline reste vert, puisqu'ils
sont en `allow_failure: true`. Le détail des variables de déploiement est dans
[RELEASE.md](RELEASE.md) §6.
