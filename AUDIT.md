# Audit des processus de développement — Orion / MicroCRM

Ce document constitue l'**état des lieux initial** de la chaîne de développement
d'Orion, avant les travaux de normalisation. Il sert de base aux recommandations
et au plan de mise en œuvre.

- Veille technologique et recommandations d'outillage → [VEILLE.md](VEILLE.md)
- Chaîne cible et table de normalisation → [schema.md](schema.md)
- État de l'implémentation → [ARCHITECTURE.md](ARCHITECTURE.md)

---

## 1. Périmètre et méthode

**Objet de l'audit.** L'application MicroCRM : un back Java/Spring Boot exposant
une API REST, un front Angular, et la chaîne d'intégration continue livrée avec.

**Sources.**

1. Le dépôt Git dans son état initial (commit `0b1e7fc`), analysé fichier par fichier.
2. Le `README.md` fourni par les équipes.
3. Les deux sondages « pratiques » et « technologies » remplis par les équipes Dev
   et Ops.

> 📌 **À compléter.** Les réponses des deux sondages doivent être synthétisées en
> §2.3. Les constats ci-dessous portent sur ce qui est vérifiable dans le dépôt ;
> le ressenti des équipes vient les confirmer ou les nuancer.

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

### 2.2 Ce qui est absent

| Domaine             | État initial                                                        |
| ------------------- | ------------------------------------------------------------------- |
| Analyse statique    | Aucune — ni linter, ni formateur, ni SonarQube                      |
| Couverture de tests | Non mesurée : ni JaCoCo, ni `--code-coverage` côté front            |
| Sécurité            | Aucun contrôle : ni SCA, ni scan de secrets, ni scan d'image        |
| Conteneurisation    | **Aucun Dockerfile**, aucun `docker-compose.yml`                    |
| Livraison           | Aucune image produite, aucun registry                               |
| Déploiement         | Inexistant — aucun stage `deploy`, aucune cible                     |
| Rollback            | Inexistant                                                          |
| Versioning          | Aucun tag, aucune convention de commit                              |
| Garde-fous locaux   | Aucun hook Git                                                      |
| Règles de branches  | Aucune : tous les jobs sur toutes les branches                      |
| Documentation       | Le seul `README.md`, décrivant des commandes Docker sans Dockerfile |

Les tests existants sont réels mais partiels : 2 classes côté back (dont un simple
smoke test de contexte) et 6 fichiers `.spec.ts` côté front. Rien ne mesure ni
n'impose de seuil.

### 2.3 Retours des équipes Dev et Ops

> 📌 **Section à compléter** à partir des deux sondages. Points à y faire figurer :
> temps perçu entre un commit et un retour, fréquence des régressions détectées
> tard, ressenti sur la fiabilité des mises en production, niveau de maîtrise des
> outils par chacun, et répartition de la connaissance dans l'équipe.

---

## 3. Analyse SWOT

### 🟢 Forces

- **Une base CI existe déjà et fonctionne.** Le pipeline est déclaré, les jobs
  passent, les images de base sont correctement choisies (`gradle:jdk17`,
  `cypress/browsers`). L'équipe ne part pas de zéro et le réflexe « tout doit être
  testé en CI » est en place.
- **Le dépôt est propre et bien structuré.** Monorepo `back/` + `front/` clairement
  séparés, wrapper Gradle versionné, `package-lock.json` présent : les builds sont
  reproductibles.
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
- **Le README décrit une réalité qui n'existe pas.** Il documente des commandes
  `docker build` alors qu'aucun Dockerfile n'est présent. Une documentation fausse
  est plus coûteuse qu'une documentation absente : elle fait perdre du temps et
  détruit la confiance dans le reste.
- **Pas de stratégie de branches.** Tous les jobs se déclenchent partout, sans
  distinction entre une branche de travail et une branche de livraison.

### 🔵 Opportunités

- **GitLab CI est très sous-exploité.** Environnements, registry d'images intégré,
  jobs manuels, règles de déclenchement, templates : tout est déjà disponible dans
  l'outil en place, sans achat ni migration.
- **Les tests existants attendent juste d'être mesurés.** Brancher JaCoCo et LCOV
  est l'affaire de quelques lignes, et transforme immédiatement des tests
  « décoratifs » en indicateur pilotable.
- **La conteneurisation est un levier à fort effet.** Elle résout d'un coup la
  reproductibilité, la parité entre environnements et rend le déploiement
  automatisable.
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
- **Effet cliquet de la documentation fausse.** Le README périmé montre que la
  documentation n'est pas maintenue avec le code. Si rien ne change, chaque
  nouveau document subira le même sort.

---

## 4. Points de friction et goulots d'étranglement

| #   | Friction                                              | Effet mesurable                                                     |
| --- | ----------------------------------------------------- | ------------------------------------------------------------------- |
| 1   | Aucun retour qualité avant la revue humaine           | Les erreurs de style et les bugs simples occupent le temps de revue |
| 2   | Détection tardive : tout remonte en CI, rien en local | Boucle de retour longue, minutes de calcul gaspillées               |
| 3   | Mise en production manuelle                           | Étape non reproductible, dépendante d'une personne                  |
| 4   | Pas de rollback outillé                               | Temps de rétablissement non maîtrisé en cas d'incident              |
| 5   | Pas d'environnement de validation                     | Les régressions sont découvertes par les utilisateurs finaux        |
| 6   | Documentation absente ou fausse                       | Onboarding lent, dépendance aux personnes                           |

**Le goulot principal** est l'absence totale d'automatisation après le `build` :
tout le travail réalisé en amont (tests, compilation) n'est pas capitalisé, puisque
la livraison repose ensuite sur des gestes manuels.

---

## 5. Recommandations

Priorisées par rapport valeur / effort.

| Priorité | Recommandation                                               | Effet attendu                                      |
| -------- | ------------------------------------------------------------ | -------------------------------------------------- |
| **P0**   | Conteneuriser les deux applications (Dockerfile multi-stage) | Débloque livraison et déploiement                  |
| **P0**   | Ajouter un stage `security` (SCA + scan d'image + secrets)   | Supprime le risque le plus élevé                   |
| **P0**   | Mesurer la couverture et poser un seuil                      | Rend la qualité pilotable                          |
| **P1**   | Ajouter un stage `lint` et des hooks pre-commit              | Raccourcit la boucle de retour, allège les revues  |
| **P1**   | Brancher SonarQube et une Quality Gate                       | Mesure objective de la dette                       |
| **P1**   | Formaliser GitFlow et le nommage des branches                | Déclenchements maîtrisés, historique lisible       |
| **P2**   | Automatiser le déploiement et le rollback par scripts        | Reproductibilité, temps de rétablissement maîtrisé |
| **P2**   | Versionner en SemVer avec des tags                           | Traçabilité de ce qui est livré                    |
| **P2**   | Documenter la chaîne et maintenir la doc avec le code        | Casse la concentration de connaissance             |

---

## 6. Début du plan de normalisation

Le pipeline cible et sa table de normalisation détaillée sont dans
[schema.md](schema.md). En résumé, la trajectoire est la suivante :

| Étape            | État initial  | Cible                                         |
| ---------------- | ------------- | --------------------------------------------- |
| Contrôles locaux | Aucun         | husky + lint-staged + commitlint              |
| Lint / format    | Aucun         | Stage `lint` : ESLint, Checkstyle, ShellCheck |
| Tests            | Stage `test`  | Stage `test` + mesure de couverture           |
| Qualité          | Aucune        | Stage `quality` : Sonar, SpotBugs, seuil      |
| Sécurité         | Aucune        | Stage `security` : SCA, secrets, misconfig    |
| Build            | Stage `build` | Inchangé                                      |
| Livraison        | Aucune        | Stage `package` : images taguées par SHA      |
| Déploiement      | Manuel        | Stage `deploy` : staging + production         |
| Rollback         | Aucun         | Automatique et manuel, outillé par scripts    |

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

## 7. Plan de sécurité — première version

### 7.1 Failles et risques identifiés dans la chaîne initiale

| #   | Risque                                                | Gravité      | Explication                                                                             |
| --- | ----------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------- |
| R1  | CVE non détectées dans les dépendances                | **Critique** | Aucun SCA. La majorité du code livré est celui des bibliothèques.                       |
| R2  | CVE non détectées dans les couches système des images | **Critique** | Aucun scan d'image : OS, JRE et serveur web ont aussi leurs CVE.                        |
| R3  | Fuite de secret par commit accidentel                 | **Élevée**   | Aucune détection automatique. L'historique est propre, mais rien ne le garantit demain. |
| R4  | Déploiement d'un artefact non vérifié                 | **Élevée**   | Aucun contrôle entre le build et la production.                                         |
| R5  | API exposée sans authentification, CORS permissif     | **Élevée**   | `allowedOrigins("*")` sur toutes les méthodes, aucune authentification.                 |
| R6  | Absence de traçabilité de ce qui est en production    | **Moyenne**  | Sans tag ni image immuable, impossible de savoir quelle version tourne.                 |
| R7  | Conteneurs exécutés en `root`                         | **Moyenne**  | Élargit la surface d'attaque en cas de compromission.                                   |
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

### 7.3 Contrôles retenus

| Risque | Contrôle                                    | Outil                       | Moment           |
| ------ | ------------------------------------------- | --------------------------- | ---------------- |
| R1     | Analyse des dépendances (SCA)               | OWASP Dependency-Check      | Stage `security` |
| R2     | Scan des couches système de l'image         | Trivy                       | Stage `package`  |
| R3     | Détection de secrets                        | Trivy (`--scanners secret`) | Stage `security` |
| R4     | Quality Gate avant livraison                | SonarQube + script dédié    | Stage `quality`  |
| R5, R8 | Analyse statique de sécurité                | SonarQube, Find-Sec-Bugs    | Stage `quality`  |
| R6     | Image immuable taguée par SHA + tags SemVer | Registry GitLab             | Stage `package`  |
| R7     | Utilisateur non privilégié dans les images  | Dockerfile                  | Build            |
| Tous   | Secrets en variables CI/CD masquées         | GitLab CI/CD Variables      | Permanent        |

Le détail de mise en œuvre de chaque contrôle est dans [QUALITY.md](QUALITY.md).

> 📌 **À compléter en fin de projet** : le processus de traitement d'une
> vulnérabilité détectée (qui arbitre, sous quel délai, comment on documente une
> exception), ainsi que la politique de mise à jour des dépendances.
