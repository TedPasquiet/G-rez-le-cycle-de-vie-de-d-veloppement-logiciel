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

> **Mise à jour du 2026-09-22.** Le contrôle R6 est en place : la version d'une
> release est un tag Git SemVer qui se propage jusqu'à l'image, par promotion et
> non par reconstruction — `back:1.0.0` et `back:<sha>` désignent le même digest.
> Voir [RELEASE.md](RELEASE.md) §2.1.

---

## 7.4 Traiter une vulnérabilité détectée

Ce processus n'est pas une intention : il est **imposé par la chaîne** depuis le
2026-09-19, date à laquelle les quatre portes de sécurité sont devenues
bloquantes. Avant cette date elles étaient en `allow_failure` et ne décidaient
de rien.

### 7.4.1 Ce qui déclenche

| Porte                            | Ce qu'elle voit                                   | Seuil          | Étape      |
| -------------------------------- | ------------------------------------------------- | -------------- | ---------- |
| `dependency-check-back`          | CVE des dépendances Java                          | CVSS ≥ 7       | `security` |
| `trivy-fs`                       | Secrets commités, misconfigurations, CVE du dépôt | HIGH, CRITICAL | `security` |
| `package-back` / `package-front` | CVE des couches système de l'image                | HIGH, CRITICAL | `package`  |

Le seuil de Dependency-Check est `failBuildOnCVSS = 7` (`back/build.gradle`), ce
qui correspond à la borne basse de la sévérité HIGH du CVSS v3. Les deux
familles d'outils s'arrêtent donc au même niveau de gravité, ce qui évite qu'une
CVE bloque d'un côté et passe de l'autre.

### 7.4.2 Sous quel délai

**Zéro, et par construction.** Une porte bloquante ne laisse pas le choix entre
traiter et remettre à plus tard : rien n'est livré tant que la découverte n'a pas
été arbitrée. C'est tout l'intérêt d'avoir retiré les `allow_failure` — un
contrôle qui signale sans arrêter finit par être lu comme du bruit.

La contrepartie est assumée : une CVE publiée dans une dépendance transitive peut
bloquer une livraison sans rapport avec le changement en cours. C'est le prix, et
il est préférable à une livraison qui ignore ce qu'elle emporte.

### 7.4.3 Les trois issues, dont une seule est la voie normale

1. **Corriger** — monter la version de la dépendance ou de l'image de base.
   C'est la voie par défaut, et celle qui doit être tentée en premier.
2. **Inscrire une exception motivée** — uniquement quand la vulnérabilité ne
   s'applique pas au contexte, ou quand aucun correctif n'existe et que le
   risque résiduel est acceptable et écrit.
3. **Arrêter la livraison** — quand ni l'un ni l'autre n'est possible. Ne rien
   livrer reste une décision valable.

**Exemple vécu, issue n°1.** Le 2026-09-19, Trivy a bloqué sur des CVE des
couches système. La réponse a été de monter Spring Boot de 3.2.5 à 3.5.16 et de
recompiler Caddy, et non d'inscrire une exception — commit `df1634f`. Les deux
images sortent depuis à zéro CVE HIGH ou CRITICAL.

### 7.4.4 Qui arbitre, et où s'écrit une exception

**L'arbitrage passe par la revue de merge request, pas par une décision
individuelle.** C'est une conséquence du format retenu : une exception n'existe
que sous la forme d'une entrée dans un fichier versionné. Elle arrive donc dans
une MR, avec sa justification, et ne peut pas être posée en silence par la
personne que le pipeline dérange.

Deux registres, selon la nature :

| Registre                                        | Ce qu'il couvre                    | État actuel |
| ----------------------------------------------- | ---------------------------------- | ----------- |
| `.trivyignore.yaml`                             | Misconfigurations et CVE d'image   | 4 entrées   |
| `back/config/dependency-check/suppressions.xml` | CVE de dépendances (faux positifs) | **vide**    |

Trois règles de forme, et elles ne sont pas décoratives :

- **Une exception est bornée à un chemin.** Le format historique `.trivyignore`
  applique un identifiant à tout le dépôt : ignorer `KSV-0014` pour un manifeste
  masquerait le jour où un autre perdrait vraiment son `readOnlyRootFilesystem`.
  C'est la raison pour laquelle `.trivyignore` est conservé **vide** et que les
  jobs passent explicitement `--ignorefile .trivyignore.yaml`.
- **Une exception porte une justification écrite**, qui dit pourquoi la
  vulnérabilité ne s'applique pas — pas qu'elle dérange.
- **Une exception porte une date de revue** (`expiredAt`). Ce n'est pas une
  décharge permanente : le fichier est relu à chaque release, et une entrée
  expirée redevient bloquante d'elle-même.

### 7.4.5 Ce que ce processus ne couvre pas encore

**Un écart entre Dependency-Check et Trivy n'a jamais été expliqué** :
Dependency-Check ne remontait pas des CVE Tomcat que Trivy voyait. Les deux
outils regardent des périmètres différents — les dépendances déclarées pour l'un,
les couches de l'image pour l'autre — ce qui explique peut-être tout, mais ne l'a
pas été. Les deux portes étant désormais bloquantes, la première exécution réelle
de la chaîne tranchera.

---

## 7.5 Politique de mise à jour des dépendances

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
Renovate. Ce n'est pas un choix argumenté, c'est une absence. Renovate est
l'option la plus adaptée ici : il couvre Gradle, npm **et** les images Docker
d'un fichier CI GitLab, c'est-à-dire les trois registres du tableau ci-dessus, là
où Dependabot ignorerait le troisième. C'est l'évolution naturelle de cette
politique, et elle est chiffrée comme telle.
