# Qualité, sécurité et supervision

Cinq outils sont branchés sur le cycle de vie de MicroCRM. Chacun couvre un angle
que les autres ne voient pas : un test unitaire ne détecte pas une CVE, et un scan
de CVE ne détecte pas une mauvaise pratique de code.

| Outil                          | Question à laquelle il répond                                                  | Où il s'exécute  |
| ------------------------------ | ------------------------------------------------------------------------------ | ---------------- |
| **SonarQube**                  | Le code respecte-t-il les bonnes pratiques ? Quelle est la dette ?             | stage `quality`  |
| **SpotBugs** (+ Find-Sec-Bugs) | Y a-t-il des bugs latents dans le bytecode ?                                   | stage `quality`  |
| **OWASP Dependency-Check**     | Mes dépendances Java portent-elles des CVE connues ?                           | stage `security` |
| **Trivy**                      | Mes images Docker et mes fichiers portent-ils des CVE / secrets / misconfigs ? | stage `security` |
| **Spring Boot Actuator**       | L'application déployée est-elle en bonne santé ?                               | à l'exécution    |

Le pipeline s'organise donc en quatre étapes : `test` → `quality` → `security` → `build`.

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

**En CI.** Les jobs `sonarqube-back` et `sonarqube-front` ne se déclenchent que si la
variable CI/CD `SONAR_TOKEN` existe (avec `SONAR_HOST_URL`). Sans elles, le pipeline
reste vert et les jobs sont simplement ignorés. `-Dsonar.qualitygate.wait=true` fait
échouer le job si la Quality Gate n'est pas franchie.

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

Côté front, le job `dependency-check-front` joue l'équivalent avec `npm audit`.

---

## 4. Trivy — CVE des images Docker, secrets et misconfigurations

**Pourquoi.** Dependency-Check ne voit que les dépendances Java. L'image livrée
contient aussi un OS (Alpine), une JRE, un serveur web (Caddy) — chacun avec ses
propres CVE. Trivy scanne les **couches système** de l'image finale. Il détecte en
prime les **secrets commités** et les **mauvaises configurations** de Dockerfile.

> Exemples concrets sur ce projet : `front/Dockerfile` tourne en `root` (DS-0002),
> et plusieurs CVE HIGH sont ouvertes sur les paquets `@angular/*`.

**Deux jobs, deux portées.**

- `trivy-fs` (à chaque MR, rapide) : dépendances déclarées, secrets, Dockerfiles.
- `trivy-image` (branches de livraison) : construit les deux images et scanne leurs
  couches système. `--ignore-unfixed` masque les CVE sans correctif disponible.

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

## 5. Spring Boot Actuator — supervision de l'application déployée

**Pourquoi.** Les quatre outils précédents agissent **avant** le déploiement.
Actuator répond à la question d'après : une fois en production, l'application
répond-elle, sa base est-elle joignable, quelle est sa consommation mémoire ?
C'est aussi ce qui permet à Docker et à l'orchestrateur de savoir quand router
du trafic vers un conteneur.

**Endpoints exposés** (configurés dans `back/src/main/resources/application.properties`) :

| Endpoint                         | Usage                                                       |
| -------------------------------- | ----------------------------------------------------------- |
| `GET /actuator/health`           | État global (`UP` / `DOWN`)                                 |
| `GET /actuator/health/liveness`  | Le processus est vivant — sinon, redémarrer                 |
| `GET /actuator/health/readiness` | Prêt à recevoir du trafic — sinon, retirer du load balancer |
| `GET /actuator/info`             | Nom, description, version de la JVM et de l'OS              |
| `GET /actuator/metrics`          | Mémoire, threads, pool de connexions, latences HTTP         |

Seuls ces quatre endpoints sont exposés (`management.endpoints.web.exposure.include`) :
exposer `env`, `beans` ou `heapdump` en production divulguerait la configuration
interne. Le détail du health est en `when_authorized` pour la même raison.

**Vérification.**

```shell
cd back && ./gradlew bootRun
curl http://localhost:8080/actuator/health
curl http://localhost:8080/actuator/health/readiness
curl http://localhost:8080/actuator/info
```

**Branchement Docker.** `back/Dockerfile` déclare un `HEALTHCHECK` sur
`/actuator/health/readiness`, et `docker-compose.yml` ne démarre le front
qu'une fois le back `service_healthy`.

> Pour aller plus loin : ajouter `io.micrometer:micrometer-registry-prometheus`
> et `prometheus` à la liste des endpoints exposés permet à Prometheus/Grafana
> de scraper `/actuator/prometheus`.

---

## Récapitulatif des variables CI/CD à créer dans GitLab

| Variable         | Obligatoire | Rôle                                |
| ---------------- | ----------- | ----------------------------------- |
| `SONAR_HOST_URL` | pour Sonar  | URL du serveur SonarQube            |
| `SONAR_TOKEN`    | pour Sonar  | Token d'analyse (masquée)           |
| `NVD_API_KEY`    | non         | Accélère Dependency-Check (masquée) |

Sans `SONAR_TOKEN`, les jobs Sonar sont simplement ignorés : le reste du pipeline
fonctionne à l'identique.
