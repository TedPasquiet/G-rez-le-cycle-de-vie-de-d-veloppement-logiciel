# Audit des processus de développement — Orion / MicroCRM

Ce document constitue l'**état des lieux initial** de la chaîne de développement
d'Orion, avant les travaux de normalisation. Il sert de base aux recommandations
et au plan de mise en œuvre. Seul le plan de sécurité (§7) décrit les contrôles
en vigueur.

- Veille technologique et recommandations d'outillage → [VEILLE.md](VEILLE.md)
- Chaîne cible et table de normalisation → [schema.md](schema.md)
- État de l'implémentation → [ARCHITECTURE.md](ARCHITECTURE.md)

---

## 1. Périmètre et méthode

**Objet de l'audit.** L'application MicroCRM : un back Java/Spring Boot exposant
une API REST, un front Angular, et la chaîne d'intégration continue livrée avec.

**Sources.**

1. Le dépôt Git dans son état initial (commits `0b1e7fc` du 13 mai 2024 et
   `4298760` du 29 mai 2024), analysé fichier par fichier.
2. Le `README.md` fourni par les équipes.
3. Les deux sondages « pratiques » et « technologies » remplis par les équipes Dev
   et Ops (§2.3).

**Méthode.** Analyse statique du dépôt (configuration CI, outillage, tests,
conteneurisation, gestion des secrets), puis restitution en SWOT.

---

## 2. État initial de la chaîne

### 2.1 Le pipeline livré

Le `.gitlab-ci.yml` initial tient en **2 stages et 4 jobs** :

```yaml
stages:
  - test
  - build

test-front # Karma / Chrome headless
test-back # gradle test
build-front # ng build --optimization
build-back # gradle build
```

C'est un pipeline d'**intégration** au sens strict : il compile et lance les tests.
Il s'arrête là.

### 2.2 Ce qui est absent ou inexploité

| Domaine             | État initial                                                                            |
| ------------------- | --------------------------------------------------------------------------------------- |
| Analyse statique    | Aucune — ni linter, ni formateur, ni SonarQube                                          |
| Couverture de tests | Non mesurée : ni JaCoCo, ni `--code-coverage` côté front                                |
| Sécurité            | Aucun contrôle : ni SCA, ni scan de secrets, ni scan d'image                            |
| Conteneurisation    | Un `Dockerfile` multi-étapes à la racine, **que la CI n'utilise pas** ; aucun compose   |
| Livraison           | Aucune image construite ni poussée par la CI, aucun registry                            |
| Déploiement         | Inexistant — aucun stage `deploy`, aucune cible                                         |
| Rollback            | Inexistant                                                                              |
| Versioning          | Aucun tag, aucune convention de commit                                                  |
| Garde-fous locaux   | Aucun hook Git                                                                          |
| Règles de branches  | Aucune : tous les jobs sur toutes les branches                                          |
| Documentation       | Le seul `README.md`, qui documente des commandes `docker build` que la CI n'exécute pas |

**Le Dockerfile initial.** Un fichier unique à la racine, accompagné d'un
`.dockerignore`, construit trois cibles : `front` (Caddy sur Alpine), `back`
(JRE 21 sur Alpine) et `standalone` (les deux dans un même conteneur, sous
supervisord). Le README documente les commandes `docker build --target …`
correspondantes. Ce Dockerfile a quatre défauts :

- **images de base non figées** (`node`, `gradle:jdk17`) : deux constructions à
  quelques semaines d'écart ne partent pas de la même base ;
- **compilation en JDK 17, exécution en JRE 21** : la version testée n'est pas
  celle qui tourne ;
- **`EXPOSE 4200` pour un back qui écoute sur 8080** : le port déclaré est faux ;
- **aucun utilisateur non privilégié** : les conteneurs tournent en `root`.

Surtout, **la CI ne s'en sert pas** : aucune image n'est construite, scannée ni
poussée. Une image éventuellement produite l'est à la main, hors de toute trace.

Les tests existants sont réels mais partiels : 2 classes côté back (dont un simple
smoke test de contexte) et 6 fichiers `.spec.ts` côté front. Rien ne mesure ni
n'impose de seuil.

### 2.3 Retours des équipes Dev et Ops

Les deux équipes d'Orion ont répondu au sondage « pratiques et technologies ».
Les sondages eux-mêmes ne sont pas versionnés dans ce dépôt ; ce qui suit en
reprend la restitution faite dans `docs/documentation-ci-cd-complete.md` §2.1 et
`docs/plan-optimisation-release.md` §1-2.

| Source          | Ce qui est dit                                                                                                                                              | Ce que ça révèle                                               |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Sondage Ops, Q3 | « La majorité des opérations sont aujourd'hui manuelles et mériteraient d'être automatisées, notamment les contrôles de sécurité ainsi que le déploiement » | Le déploiement dépend d'une personne et de sa disponibilité    |
| Sondage Dev, Q2 | « Nous avons reçu dès le début un retour sur des CVEs présentes dans l'image, ce qui a retardé le premier déploiement »                                     | Le contrôle de sécurité arrive après la remise, donc trop tard |
| Sondage Ops, Q4 | Besoin d'un dépôt d'images interne, et d'une analyse de sécurité des images **en amont**                                                                    | L'équipe Ops demande elle-même que le contrôle remonte         |
| Sondage Dev, Q4 | Besoin d'analyse statique et d'aide à la conception                                                                                                         | L'équipe se dit débutante en Java, Spring Boot, Gradle, JUnit  |
| Les deux        | Aucune compétence Kubernetes déclarée                                                                                                                       | La cible repose sur un savoir que personne n'a encore          |

**Le cycle déclaré est deux cycles, reliés par un email.** Côté Dev, sept
étapes, du backlog à la génération des images et à l'envoi de leurs références.
Côté Ops, trois : réception d'un numéro de version, analyse Trivy de l'image,
déploiement manuel en commandes Docker. Rien n'est partagé entre les deux — ni
dépôt d'images, ni historique des déploiements, ni indicateur. Quand le scan
trouve une CVE, l'image repart chez son auteur : c'est le « retour à
l'envoyeur ».

**Ce que la collaboration y perd.** Chaque équipe travaille sur ce qu'elle
reçoit, sans voir ce que l'autre a fait ni pourquoi. L'équipe Dev n'apprend
qu'une image est refusée qu'après l'avoir remise ; l'équipe Ops ne sait d'une
version que son numéro. La réponse apportée par la chaîne — un dépôt unique, des
portes dans le pipeline de l'auteur, des environnements et des indicateurs
visibles de tous — est décrite dans `docs/documentation-ci-cd-complete.md` §2.3.

**Ce que les sondages ne disent pas, d'après ce que le dépôt en restitue.**
Aucun chiffre sur le temps perçu entre un commit et un retour, ni sur la
fréquence des régressions découvertes tard, ni sur la répartition de la
connaissance dans l'équipe. Ces points restent des constats d'audit (§4), pas
des retours d'équipe.

---

## 3. Analyse SWOT

### 🟢 Forces

- **Une base CI existe déjà et fonctionne.** Le pipeline est déclaré et les jobs
  passent. L'équipe ne part pas de zéro et le réflexe « tout doit être testé en
  CI » est en place.
- **Un Dockerfile multi-étapes existe.** Il sépare déjà construction et
  exécution, et vise des bases Alpine légères : c'est un point de départ, pas
  une page blanche.
- **Le dépôt est propre et bien structuré.** Monorepo `back/` + `front/` clairement
  séparés, wrapper Gradle versionné, `package-lock.json` présent : les
  dépendances applicatives sont figées.
- **Des tests existent des deux côtés.** C'est loin d'être toujours le cas, et ça
  fournit un point d'appui immédiat pour brancher la mesure de couverture.
- **Aucun secret dans le code.** Vérifié sur l'ensemble de l'historique : aucun
  token, mot de passe ou clé privée n'a jamais été commité. L'hygiène de base est
  respectée.
- **Un stack technique standard et documenté.** Spring Boot, Angular, Gradle,
  GitLab CI : aucune techno exotique, la montée en compétence est facilitée et le
  recrutement aussi.

### 🔴 Faiblesses

- **La chaîne s'arrête à la compilation.** Il n'y a ni livraison ni déploiement :
  c'est de l'intégration continue, pas du CI/CD. Le passage en production reste
  entièrement manuel, donc non reproductible et non traçable.
- **Aucun contrôle de sécurité.** Ni analyse des dépendances, ni scan d'image, ni
  détection de secrets. Une CVE de type Log4Shell passerait totalement inaperçue.
- **Aucune mesure de la qualité.** Sans couverture ni analyse statique, la dette
  technique s'accumule sans signal. Personne ne peut dire si un changement dégrade
  le code.
- **Aucun garde-fou avant le push.** Pas de hook, pas de convention de commit :
  la CI découvre des erreurs qu'un contrôle local aurait détectées en deux
  secondes, ce qui consomme du temps machine et allonge la boucle de retour.
- **Le Dockerfile est hors de la chaîne et non reproductible.** La CI ne
  l'exécute pas ; ses images de base ne sont pas figées ; il compile en JDK 17
  et exécute en JRE 21 ; il déclare le port 4200 pour un back qui écoute
  sur 8080 ; il fait tourner les conteneurs en `root`. Le README en documente
  l'usage manuel : une image peut donc exister sans qu'aucun contrôle ne l'ait vue.
- **Pas de stratégie de branches.** Tous les jobs se déclenchent partout, sans
  distinction entre une branche de travail et une branche de livraison.

### 🔵 Opportunités

- **GitLab CI est très sous-exploité.** Environnements, registry d'images intégré,
  jobs manuels, règles de déclenchement, templates : tout est déjà disponible dans
  l'outil en place, sans achat ni migration.
- **Les tests existants attendent juste d'être mesurés.** Brancher JaCoCo et LCOV
  est l'affaire de quelques lignes, et transforme immédiatement des tests
  « décoratifs » en indicateur pilotable.
- **Le Dockerfile existant ne demande qu'à être branché.** Le scinder par
  composant, figer ses bases, aligner les versions de Java et le faire
  exécuter par la CI règle d'un coup la reproductibilité, la parité entre
  environnements, et rend le déploiement automatisable.
- **L'écosystème de sécurité est gratuit et mature.** SonarQube, Trivy, OWASP
  Dependency-Check s'intègrent en quelques lignes de YAML, sans licence.
- **Le projet est jeune.** Poser les conventions maintenant coûte infiniment moins
  cher que de les rétro-appliquer sur deux ans d'historique.

### 🟠 Menaces

- **Dette de sécurité invisible et croissante.** Chaque jour sans SCA augmente le
  risque d'exposer une CVE connue en production sans le savoir. C'est le risque
  principal.
- **Concentration de la connaissance.** La chaîne n'est documentée nulle part :
  elle ne vit que dans la tête de ceux qui l'ont écrite. Un départ, et plus
  personne ne sait la faire évoluer ni la réparer.
- **Régression silencieuse de la couverture.** Sans seuil, la couverture ne peut
  que baisser au fil des livraisons.
- **Déploiement manuel = incident de production.** Une mise en production non
  scriptée finit toujours par diverger de la procédure. Et sans rollback outillé,
  le temps de rétablissement dépend de l'improvisation.
- **Divergence entre la documentation et la chaîne.** Le README décrit une
  construction d'images que la CI ignore : ce qui est documenté n'est pas ce qui
  est contrôlé. Si rien ne change, chaque nouveau document s'écartera de la même
  façon de ce qui tourne réellement.

---

## 4. Points de friction et goulots d'étranglement

| #   | Friction                                                           | Effet mesurable                                                     |
| --- | ------------------------------------------------------------------ | ------------------------------------------------------------------- |
| 1   | Aucun retour qualité avant la revue humaine                        | Les erreurs de style et les bugs simples occupent le temps de revue |
| 2   | Détection tardive : tout remonte en CI, rien en local              | Boucle de retour longue, minutes de calcul gaspillées               |
| 3   | Mise en production manuelle                                        | Étape non reproductible, dépendante d'une personne                  |
| 4   | Pas de rollback outillé                                            | Temps de rétablissement non maîtrisé en cas d'incident              |
| 5   | Pas d'environnement de validation                                  | Les régressions sont découvertes par les utilisateurs finaux        |
| 6   | Documentation partielle : la construction Docker est hors de la CI | Onboarding lent, dépendance aux personnes                           |

**Le goulot principal** est l'absence totale d'automatisation après le `build` :
tout le travail réalisé en amont (tests, compilation) n'est pas capitalisé, puisque
la livraison repose ensuite sur des gestes manuels.

---

## 5. Recommandations

Priorisées par rapport valeur / effort.

| Priorité | Recommandation                                                                                                                                                 | Effet attendu                                      |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| **P0**   | Remettre le Dockerfile en état (un par composant, bases figées, Java aligné, bon port, utilisateur non privilégié) et le faire construire et pousser par la CI | Débloque livraison et déploiement                  |
| **P0**   | Ajouter un stage `security` (SCA + scan d'image + secrets)                                                                                                     | Supprime le risque le plus élevé                   |
| **P0**   | Mesurer la couverture et poser un seuil                                                                                                                        | Rend la qualité pilotable                          |
| **P1**   | Ajouter un stage `lint` et des hooks pre-commit                                                                                                                | Raccourcit la boucle de retour, allège les revues  |
| **P1**   | Brancher SonarQube et une Quality Gate                                                                                                                         | Mesure objective de la dette                       |
| **P1**   | Formaliser GitFlow et le nommage des branches                                                                                                                  | Déclenchements maîtrisés, historique lisible       |
| **P2**   | Automatiser le déploiement et le rollback par scripts                                                                                                          | Reproductibilité, temps de rétablissement maîtrisé |
| **P2**   | Versionner en SemVer avec des tags                                                                                                                             | Traçabilité de ce qui est livré                    |
| **P2**   | Documenter la chaîne et maintenir la doc avec le code                                                                                                          | Casse la concentration de connaissance             |

---

## 6. Début du plan de normalisation

Le pipeline cible et sa table de normalisation détaillée sont dans
[schema.md](schema.md). En résumé, la trajectoire est la suivante :

| Étape            | État initial                 | Cible                                         |
| ---------------- | ---------------------------- | --------------------------------------------- |
| Contrôles locaux | Aucun                        | husky + lint-staged + commitlint              |
| Lint / format    | Aucun                        | Stage `lint` : ESLint, Checkstyle, ShellCheck |
| Tests            | Stage `test`                 | Stage `test` + mesure de couverture           |
| Qualité          | Aucune                       | Stage `quality` : Sonar, SpotBugs, seuil      |
| Sécurité         | Aucune                       | Stage `security` : SCA, secrets, misconfig    |
| Build            | Stage `build`                | Inchangé                                      |
| Livraison        | Dockerfile non utilisé en CI | Stage `package` : images taguées par SHA      |
| Déploiement      | Manuel                       | Stage `deploy` : staging + production         |
| Rollback         | Aucun                        | Automatique et manuel, outillé par scripts    |

**Principes retenus pour la normalisation :**

1. **Shift-left** — un contrôle coûte d'autant moins cher qu'il est exécuté tôt.
2. **Un stage = une question** — chaque étape répond à une question unique et
   produit un verdict lisible.
3. **Immutabilité** — une image est construite une fois, taguée par SHA, puis
   promue d'un environnement à l'autre sans être reconstruite.
4. **Tout ce qui est répétitif est scripté** — et donc testable, versionné,
   relisible.
5. **La documentation vit dans le dépôt**, à côté du code qu'elle décrit.

---

## 7. Plan de sécurité

### 7.1 Failles et risques identifiés dans la chaîne initiale

| #   | Risque                                                | Gravité      | Explication                                                                             |
| --- | ----------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------- |
| R1  | CVE non détectées dans les dépendances                | **Critique** | Aucun SCA. La majorité du code livré est celui des bibliothèques.                       |
| R2  | CVE non détectées dans les couches système des images | **Critique** | Aucun scan d'image : OS, JRE et serveur web ont aussi leurs CVE.                        |
| R3  | Fuite de secret par commit accidentel                 | **Élevée**   | Aucune détection automatique. L'historique est propre, mais rien ne le garantit demain. |
| R4  | Déploiement d'un artefact non vérifié                 | **Élevée**   | Aucun contrôle entre le build et la production.                                         |
| R5  | API exposée sans authentification, CORS permissif     | **Élevée**   | `allowedOrigins("*")` sur toutes les méthodes, aucune authentification.                 |
| R6  | Absence de traçabilité de ce qui est en production    | **Moyenne**  | Sans tag ni image immuable, impossible de savoir quelle version tourne.                 |
| R7  | Conteneurs exécutés en `root`                         | **Moyenne**  | Le Dockerfile ne déclare aucun utilisateur ; la surface d'attaque s'en trouve élargie.  |
| R8  | Vulnérabilités applicatives (OWASP Top 10)            | **Moyenne**  | Aucune analyse statique orientée sécurité.                                              |

### 7.2 Objectifs de sécurité

1. **Détecter avant de livrer** — aucune vulnérabilité connue de sévérité HIGH ou
   CRITICAL ne doit atteindre la production sans avoir été vue et arbitrée.
2. **Ne jamais exposer de secret** — aucun secret dans le code ni dans les logs,
   tous injectés par variables d'environnement protégées.
3. **Savoir ce qui tourne** — toute version en production doit être identifiable
   et reliable à un commit précis.
4. **Réduire la surface d'attaque** — images minimales, utilisateur non privilégié,
   dépendances à jour.
5. **Pouvoir revenir en arrière vite** — le rollback est un contrôle de sécurité.

### 7.3 Contrôles en vigueur

| Risque | Contrôle                                                                              | Outil                                    | Moment                           |
| ------ | ------------------------------------------------------------------------------------- | ---------------------------------------- | -------------------------------- |
| R1     | Analyse des dépendances Java (SCA), 82 jars du `runtimeClasspath`                     | OWASP Dependency-Check                   | Stage `security`                 |
| R1, R3 | CVE du dépôt, secrets commités, misconfigurations                                     | Trivy (`trivy-fs`)                       | Stage `security`                 |
| R2, R4 | Scan de l'image **entre la construction et le push**                                  | Trivy (`package-back`, `package-front`)  | Stage `package`                  |
| R4     | Quality Gate avant livraison                                                          | SonarQube + `scripts/ci/quality_gate.py` | Stage `quality`                  |
| R5     | Origines CORS fixées par configuration (`microcrm.cors.allowed-origins`)              | Spring Data REST, ConfigMap Kubernetes   | Déploiement                      |
| R5, R8 | Analyse statique                                                                      | SonarQube, SpotBugs                      | Stage `quality`                  |
| R6     | Image immuable taguée par SHA, promue sous le tag SemVer ; Release GitLab par version | Registry GitLab, job `release`           | Stage `package` (tag de version) |
| R7     | Utilisateur non privilégié (`USER app`) dans les deux images                          | `back/Dockerfile`, `front/Dockerfile`    | Build                            |
| Tous   | Secrets en variables CI/CD masquées                                                   | GitLab CI/CD Variables                   | Permanent                        |
| Tous   | Rapports de scan en artefacts JSON, lus par un tableau de bord                        | `collect_security.py`, Kibana            | À chaque pipeline                |

Le détail de mise en œuvre de chaque contrôle est dans [QUALITY.md](QUALITY.md) ;
la promotion par tag et la Release dans [RELEASE.md](RELEASE.md) §2 ; le tableau
de bord « sécurité » dans [MONITORING.md](MONITORING.md) §8.

**Ce qui n'est pas couvert.** L'API n'a toujours aucune authentification (R5) :
le CORS restreint les navigateurs, pas un client qui appelle l'API directement.

---

### 7.4 Traiter une vulnérabilité détectée

Ce processus est **imposé par la chaîne** : les quatre portes de sécurité sont
bloquantes (`allow_failure: false`). Un contrôle qui signale sans arrêter finit
par être lu comme du bruit.

#### 7.4.1 Ce qui déclenche

| Porte                            | Ce qu'elle voit                                               | Seuil          | Étape      |
| -------------------------------- | ------------------------------------------------------------- | -------------- | ---------- |
| `dependency-check-back`          | CVE des dépendances Java du `runtimeClasspath` (82 jars)      | CVSS ≥ 7       | `security` |
| `trivy-fs`                       | Secrets commités, misconfigurations, CVE du dépôt             | HIGH, CRITICAL | `security` |
| `package-back` / `package-front` | CVE de l'image construite : couches système et jar applicatif | HIGH, CRITICAL | `package`  |

Les trois scans Trivy passent par `scripts/ci/trivy_scan.sh`, qui écrit un
rapport JSON et un tableau en artefacts (`when: always`, donc aussi quand le job
échoue), et sort en `2` sur un constat bloquant — `1` étant réservé au scan qui
n'a pas pu avoir lieu. Dans `package-*`, le scan se fait **entre la construction
et le push** : une image refusée n'atteint pas le registry, où un tag de version
pourrait la promouvoir.

Le seuil de Dependency-Check est `failBuildOnCVSS = 7` (`back/build.gradle`), ce
qui correspond à la borne basse de la sévérité HIGH du CVSS v3. Les deux
familles d'outils s'arrêtent donc au même niveau de gravité, ce qui évite qu'une
CVE bloque d'un côté et passe de l'autre.

Le plugin Dependency-Check écarte par défaut les configurations qu'il juge « de
test », et le plugin Spring Boot fait hériter `runtimeClasspath` de l'une
d'elles : `skipTestGroups = false` est donc indispensable, sans quoi le scan
porte sur une liste vide et sort vert.

#### 7.4.2 Sous quel délai

**Zéro, et par construction.** Une porte bloquante ne laisse pas le choix entre
traiter et remettre à plus tard : rien n'est livré tant que la découverte n'a pas
été arbitrée.

La contrepartie est assumée : une CVE publiée dans une dépendance transitive peut
bloquer une livraison sans rapport avec le changement en cours. C'est le prix, et
il est préférable à une livraison qui ignore ce qu'elle emporte.

#### 7.4.3 Les trois issues, dont une seule est la voie normale

1. **Corriger** — monter la version de la dépendance ou de l'image de base.
   C'est la voie par défaut, et celle qui doit être tentée en premier.
2. **Inscrire une exception motivée** — uniquement quand la vulnérabilité ne
   s'applique pas au contexte, ou quand aucun correctif n'existe et que le
   risque résiduel est acceptable et écrit.
3. **Arrêter la livraison** — quand ni l'un ni l'autre n'est possible. Ne rien
   livrer reste une décision valable.

**Corrections en vigueur (issue n°1).** Spring Boot est en 3.5.16. Trois
versions sont forcées dans `back/build.gradle` au-dessus de celles que gère
Spring Boot, parce que la version gérée porte des CVE bloquantes : Tomcat
10.1.59, Jackson 2.21.7 (BOM entier), Log4j 2.25.5. Chaque ligne porte la
mention « à retirer dès que le BOM de Spring Boot l'atteint ».

**Exceptions en vigueur (issue n°2).** Douze CVE de Spring Framework 6.2.19 ne
sont levées par aucune version publique : la 6.2.20 est réservée au support
payant de Spring, et le correctif en source ouverte est Spring Framework 7.0.9,
donc Spring Boot 4 — une migration majeure. Elles sont exceptées, chacune avec
un fait vérifiable dans le dépôt (§7.4.4).

#### 7.4.4 Qui arbitre, et où s'écrit une exception

**L'arbitrage passe par la revue de merge request, pas par une décision
individuelle.** C'est une conséquence du format retenu : une exception n'existe
que sous la forme d'une entrée dans un fichier versionné. Elle arrive donc dans
une MR, avec sa justification, et ne peut pas être posée en silence par la
personne que le pipeline dérange.

Deux registres, selon la nature :

| Registre                                        | Ce qu'il couvre                                  | Contenu                                            |
| ----------------------------------------------- | ------------------------------------------------ | -------------------------------------------------- |
| `.trivyignore.yaml`                             | Misconfigurations et CVE relevées par Trivy      | **7 entrées**, revue au 2026-12-31                 |
| `back/config/dependency-check/suppressions.xml` | CVE de dépendances relevées par Dependency-Check | **3 entrées couvrant 12 CVE**, jusqu'au 2026-12-31 |

**Les exceptions en cours.** Les fichiers font foi ; ce tableau en est le
résumé.

| Identifiant                                       | Où                                                  | Pourquoi l'exception est accordée                                                                                                                                                                       |
| ------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KSV-0056`, `KSV-0041`                            | `.gitlab/agents/microcrm/rbac.yaml`                 | Droits de l'agent GitLab sur les ressources réseau (les `NetworkPolicy` de Terraform) et sur les Secrets (celui du registry) : assumés, à l'échelle du cluster, sans `list` ni `delete` sur les Secrets |
| `KSV-0014`                                        | `k8s/elk/elasticsearch-deployment.yaml`             | Elasticsearch ne démarre pas avec une racine en lecture seule                                                                                                                                           |
| `KSV-0014`, `KSV-0118`                            | `k8s/overlays/production/back-resources-patch.yaml` | Un patch partiel, que Trivy lit comme un manifeste complet                                                                                                                                              |
| `DS-0031`                                         | `back/Dockerfile`                                   | Faux positif : deux variables dont le nom contient `KEY` désignent une clé de MDC, pas un secret                                                                                                        |
| `KSV-0109`                                        | `k8s/elk/apm-server-config.yaml`                    | Faux positif : le mot « secret » figure dans un commentaire                                                                                                                                             |
| CVE-2026-47885, 47888, 47889, 47891, 47892, 47893 | Spring Framework 6.2.19                             | Spring WebFlux et RSocket : ces modules ne sont pas sur le `runtimeClasspath`                                                                                                                           |
| CVE-2026-47884, 47890, 59313                      | Spring Framework 6.2.19                             | `XsltView`, Server-Sent Events, framework web fonctionnel : l'application n'a aucun contrôleur, seulement deux dépôts Spring Data REST                                                                  |
| CVE-2026-47886 (7,5), 59282 (7,5), 59283 (9,1)    | Spring Framework 6.2.19                             | SpEL et liaison de données : pour chacune, au moins une des conditions de l'avis de Spring manque. Contrôlé par exécution sur staging : trois `PATCH` forgés, trois `400`                               |

⚠️ **Limite : la dernière ligne est une analyse, pas une preuve que Spring
6.2.19 est sain.** L'application expose ses dépôts par Spring Data REST, dont le
`PATCH` JSON Patch traduit en SpEL des chemins fournis par le client.
L'exception tombe le jour où le modèle reçoit un champ `BigDecimal` ou
`BigInteger`, une liste auto-peuplée, où le compilateur SpEL est activé, ou où
du code applicatif évalue une expression venue d'une requête. La sortie propre
reste la migration vers Spring Boot 4.

Trois règles de forme, et elles ne sont pas décoratives :

- **Une exception est bornée à un chemin.** Le format historique `.trivyignore`
  applique un identifiant à tout le dépôt : ignorer `KSV-0014` pour un manifeste
  masquerait le jour où un autre perdrait vraiment son `readOnlyRootFilesystem`.
  C'est la raison pour laquelle `.trivyignore` est conservé **vide** et que les
  jobs passent explicitement `--ignorefile .trivyignore.yaml`.
- **Une exception porte une justification écrite**, qui dit pourquoi la
  vulnérabilité ne s'applique pas — pas qu'elle dérange.
- **Une exception porte une date de revue** (`expiredAt`, `until`). Ce n'est pas
  une décharge permanente : le fichier est relu à chaque release, et une entrée
  expirée redevient bloquante d'elle-même.

#### 7.4.5 Ce que ce processus ne couvre pas

- **Rien ne vérifie automatiquement qu'un scan a lu quelque chose.** Une porte
  bloquante qui ne lit rien ne se distingue pas, à l'œil, d'une porte qui n'a
  rien trouvé. Un contrôle du nombre de dépendances analysées dans
  `dependency-check-back` reste à écrire.
- **Les CVE de score inférieur à 7 ne sont suivies par rien.** Elles sont
  visibles dans l'artefact, sous le seuil, sans échéance.
- **Les dépendances du front n'ont pas de SCA dédiée** : aucun `npm audit`, seul
  `trivy-fs` lit le `package-lock.json`.

---

### 7.5 Politique de mise à jour des dépendances

Trois registres se mettent à jour séparément, et confondre les trois est la
première cause de mise à jour oubliée.

| Registre                 | Où                                        | Contrôlé par               |
| ------------------------ | ----------------------------------------- | -------------------------- |
| Dépendances applicatives | `back/build.gradle`, `front/package.json` | `dependency-check-back`    |
| Images de base           | `back/Dockerfile`, `front/Dockerfile`     | Trivy, à l'étape `package` |
| Images d'outillage de CI | `.gitlab/ci/variables.yml`                | aucun contrôle automatique |

**La règle commune : aucune version flottante.** Ni `latest`, ni plage ouverte.
Un tag mobile fait casser la chaîne sans qu'aucun commit ne l'explique, et rend
deux analyses incomparables. Une montée de version se fait donc dans un **commit
dédié qui dit pourquoi**, ce que les messages de commit du dépôt vérifient déjà
par convention.

**La cadence.** Trois déclencheurs, par ordre de fréquence :

1. **À chaque pipeline** — les portes de sécurité signalent ce qui est devenu
   vulnérable depuis la dernière exécution. C'est le mécanisme principal, et il
   est automatique.
2. **À chaque release** — relecture des entrées de `.trivyignore.yaml` et de
   `suppressions.xml` dont la date de revue approche.
3. **Sur publication d'une CVE majeure** touchant une brique de la pile, sans
   attendre le pipeline suivant.

**Le trou connu : le troisième registre n'est surveillé par rien.** Les images
d'outillage de la CI — `$TRIVY_IMAGE`, `$KUBECTL_IMAGE`, `$CYPRESS_IMAGE` et les
autres — sont figées, ce qui est la bonne décision, mais aucun contrôle ne
signale qu'une version figée a vieilli. Elles ne tournent pas en production, donc
le risque est indirect ; il n'est pas nul pour autant, puisqu'elles manipulent
les identifiants du registry.

**Aucun outil de mise à jour automatique n'est en place** — ni Dependabot, ni
Renovate. Renovate est l'option la plus adaptée ici : il couvre Gradle, npm
**et** les images Docker d'un fichier CI GitLab, c'est-à-dire les trois
registres du tableau ci-dessus, là où Dependabot ignorerait le troisième.
