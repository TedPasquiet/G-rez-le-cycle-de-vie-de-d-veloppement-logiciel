# Veille technologique et recommandations — chaîne CI d'Orion

Ce document répond aux faiblesses identifiées dans [AUDIT.md](AUDIT.md). Pour chaque
besoin, il compare les solutions disponibles, justifie le choix retenu et en indique
la valeur ajoutée concrète pour Orion.

**Critères de comparaison retenus :** coût (licence et temps de mise en place),
intégration avec GitLab CI, maturité et pérennité de l'outil, courbe
d'apprentissage pour une équipe qui découvre le DevOps.

---

## 1. Analyse statique et qualité du code

| Solution                   | Coût                      | Intégration GitLab    | Remarque                               |
| -------------------------- | ------------------------- | --------------------- | -------------------------------------- |
| **SonarQube / SonarCloud** | Gratuit (Community / OSS) | Native, plugin Gradle | Standard du marché, multi-langages     |
| Codacy, Code Climate       | Payant au-delà de l'OSS   | Bonne                 | Peu d'avantages sur Sonar ici          |
| Linters seuls              | Gratuit                   | Manuelle              | Pas d'historique ni de notion de dette |

**Retenu : SonarQube**, complété par des linters au plus tôt (ESLint, Checkstyle,
Spotless, Prettier).

**Pourquoi.** C'est le seul outil qui couvre à la fois le back Java et le front
TypeScript, agrège la couverture des deux, et matérialise la notion de **Quality
Gate** — un verdict binaire opposable, plutôt qu'un rapport que personne ne lit.

**Valeur ajoutée pour Orion.** L'équipe manque d'expérience Java : Sonar connaît les
idiomes du langage et de Spring, et signale ce qu'une relecture humaine peu
expérimentée laisse passer. Il transforme une revue de code subjective en un critère
mesurable, et rend la dette technique visible avant qu'elle ne devienne coûteuse.

> Le concept clé est celui de **Clean as You Code** : plutôt que d'exiger un niveau
> de qualité sur l'ensemble du code existant — décourageant et jamais atteint — la
> Quality Gate ne s'applique qu'au **code nouveau ou modifié**. La dette se résorbe
> naturellement à mesure que le code est touché.

---

## 2. Sécurité de la chaîne (DevSecOps)

C'est la lacune la plus grave de l'état initial. Trois angles distincts, trois outils.

| Besoin                          | Solutions étudiées                                       | Retenu                        |
| ------------------------------- | -------------------------------------------------------- | ----------------------------- |
| CVE des dépendances (SCA)       | OWASP Dependency-Check, Snyk, GitLab Dependency Scanning | **OWASP Dependency-Check**    |
| CVE des images, secrets, config | **Trivy**, Grype, Clair, Docker Scout                    | **Trivy**                     |
| Vulnérabilités du code (SAST)   | SonarQube + Find-Sec-Bugs, Semgrep                       | **SonarQube + Find-Sec-Bugs** |

**Pourquoi Dependency-Check plutôt que Snyk.** Snyk a une meilleure ergonomie et une
base enrichie, mais son modèle est payant au-delà d'un quota, et il impose un compte
externe. Dependency-Check est un plugin Gradle gratuit, sans limite, qui s'appuie sur
la base publique **NVD**. Pour un projet évalué sur sa maîtrise de la chaîne, la
dépendance à un SaaS payant est un risque inutile.

**Pourquoi Trivy.** Un seul binaire couvre trois usages : CVE des couches système de
l'image, détection de secrets commités, et misconfigurations de Dockerfile. Il est
rapide, ne nécessite aucun serveur, et s'utilise aussi bien en CI qu'en local via une
simple image Docker. Grype ne fait que les CVE ; Clair impose une infrastructure ;
Docker Scout est lié à l'écosystème Docker Hub.

**Pourquoi GitLab Dependency Scanning n'a pas été retenu.** Les fonctionnalités de
sécurité intégrées de GitLab (SAST, DAST, Dependency Scanning avec tableau de bord)
sont excellentes mais réservées aux **plans Ultimate**. Le projet tourne sur un plan
gratuit.

**Valeur ajoutée pour Orion.** Ces trois contrôles couvrent les risques R1, R2, R3,
R5 et R8 de l'audit — c'est-à-dire l'essentiel du risque de sécurité — pour un coût
de licence nul et environ trente lignes de YAML.

> **Principe directeur : shift-left.** Une vulnérabilité détectée à l'écriture coûte
> quelques minutes ; détectée en production, elle coûte un incident. Chaque contrôle
> est donc placé au plus tôt dans la chaîne.

---

## 3. Conteneurisation

| Solution                     | Applicabilité                                                           |
| ---------------------------- | ----------------------------------------------------------------------- |
| **Docker (multi-stage)**     | Standard universel, connu, outillage mature                             |
| Buildpacks (Paketo)          | Pas de Dockerfile à écrire, mais moins de contrôle et image plus lourde |
| Jib (Google, spécifique JVM) | Très efficace côté back, mais ne couvre pas le front                    |

**Retenu : Docker avec build multi-stage.**

**Pourquoi.** Le multi-stage répond directement à deux besoins : une **image finale
légère** (l'outillage de compilation est jeté après le build) et donc une **surface
d'attaque réduite**. C'est aussi la seule option qui traite le back et le front de la
même façon, ce qui simplifie la chaîne.

**Bonnes pratiques retenues :**

- image de base minimale (`alpine`, `caddy:2-alpine`) ;
- **utilisateur non privilégié** dans l'image finale ;
- `.dockerignore` par contexte de build, pour ne pas envoyer `node_modules` au démon ;
- **tag = SHA du commit**, jamais `latest` en déploiement.

**Valeur ajoutée pour Orion.** La conteneurisation est le déblocage principal : sans
image, pas de livraison automatisable ni de déploiement reproductible. Elle supprime
aussi le classique « ça marche sur ma machine », puisque l'artefact exécuté en
production est exactement celui qui a été testé.

---

## 4. Orchestration et déploiement

| Solution              | Coût / complexité | Adapté à Orion ?                                                                                  |
| --------------------- | ----------------- | ------------------------------------------------------------------------------------------------- |
| Docker Compose        | Très faible       | Suffisant en local, insuffisant en production (pas de rollback natif, pas de haute disponibilité) |
| **Kubernetes**        | Élevée            | **Retenu** — rollback natif, standard du marché                                                   |
| Nomad                 | Moyenne           | Plus simple, mais écosystème et emploi plus étroits                                               |
| PaaS (Heroku, Render) | Faible            | Rapide, mais peu formateur et enfermant                                                           |

**Retenu : Kubernetes en production, Docker Compose en local.**

**Pourquoi.** Un argument a pesé plus que les autres : Kubernetes **conserve
nativement l'historique des déploiements**. Un `kubectl rollout undo` restaure la
version précédente en quelques secondes, sans rien reconstruire. Le rollback — c'est-à-dire
la maîtrise du temps de rétablissement, risque R4 de l'audit — devient une commande
au lieu d'une procédure d'urgence improvisée.

Docker Compose reste l'outil du poste de développement : démarrer la stack complète
en une commande, sans cluster.

**Point de vigilance assumé.** Kubernetes a une courbe d'apprentissage réelle. Pour
une équipe qui découvre le DevOps, c'est un investissement — justifié ici par le
rollback natif et par le fait que c'est la compétence la plus demandée du marché.

---

## 5. Automatisation et fiabilité des scripts

| Besoin                  | Solution retenue           | Alternative écartée                           |
| ----------------------- | -------------------------- | --------------------------------------------- |
| Analyse statique Bash   | **ShellCheck**             | —                                             |
| Tests de scripts Bash   | **Harnais maison + stubs** | `bats` / `bash_unit` : dépendance à installer |
| Scripts d'orchestration | **Bash + Python (stdlib)** | Go, Node : surcoût de build inutile           |

**Pourquoi du Bash et du Python plutôt qu'un langage compilé.** Les deux sont
présents dans toutes les images CI, ne demandent aucune compilation, et restent
lisibles par n'importe quel membre de l'équipe. Le choix de n'utiliser que la
**bibliothèque standard** de Python évite tout `pip install` en CI : moins de temps
d'exécution, et surtout aucune dépendance supplémentaire à auditer.

**Pourquoi tester les scripts.** Un script de déploiement qui échoue mal est plus
dangereux qu'un script absent. La technique retenue consiste à **remplacer
`kubectl`, `docker` et `trivy` par de faux programmes** placés en tête de `PATH` :
on peut alors vérifier les chemins d'échec — rollback automatique, refus de pousser
une image vulnérable — sans cluster ni registry. Voir [SCRIPTS.md](SCRIPTS.md).

---

## 6. Discipline de dépôt

| Outil                   | Rôle                                             |
| ----------------------- | ------------------------------------------------ |
| **husky**               | Exécute les hooks Git, versionnés dans le dépôt  |
| **lint-staged**         | N'analyse que les fichiers indexés — donc rapide |
| **commitlint**          | Impose les Conventional Commits                  |
| **Prettier / Spotless** | Supprime les débats de formatage                 |

**Valeur ajoutée.** C'est le meilleur rapport effort/gain de toute la veille : ces
contrôles s'exécutent en local, **avant** le push. Ils raccourcissent la boucle de
retour de plusieurs minutes à quelques secondes, et économisent des minutes de calcul
GitLab — ressource limitée sur un plan gratuit.

Les Conventional Commits ne sont pas qu'une question de style : ils rendent
l'historique exploitable par machine, ce qui ouvre la **génération automatique de
changelog** et le **versioning sémantique automatisé**.

---

## 7. Synthèse : pile retenue

| Besoin           | Outil                          | Coût                       |
| ---------------- | ------------------------------ | -------------------------- |
| Orchestration CI | GitLab CI                      | Gratuit                    |
| Qualité          | SonarQube / SonarCloud         | Gratuit                    |
| Bugs (bytecode)  | SpotBugs + Find-Sec-Bugs       | Gratuit                    |
| SCA              | OWASP Dependency-Check         | Gratuit                    |
| Images & secrets | Trivy                          | Gratuit                    |
| Lint             | ESLint, Checkstyle, ShellCheck | Gratuit                    |
| Format           | Prettier, Spotless             | Gratuit                    |
| Hooks locaux     | husky, lint-staged, commitlint | Gratuit                    |
| Conteneurisation | Docker multi-stage             | Gratuit                    |
| Orchestration    | Kubernetes                     | Gratuit (hors hébergement) |
| Scripts          | Bash, Python (stdlib)          | Gratuit                    |

**Coût total de licence : nul.** L'investissement est en temps de mise en place et
en montée en compétence, pas en budget logiciel.

---

## 8. Pistes non retenues à ce stade

Écartées pour rester dans le périmètre, mais pertinentes pour la suite :

- **Tests E2E** (Cypress, Playwright) — la vraie lacune de la stratégie de test
  actuelle : rien ne vérifie que le front et le back fonctionnent ensemble.
  C'est la première évolution que je recommanderais.
- **Supervision applicative** (Spring Boot Actuator + Prometheus/Grafana) —
  indispensable dès qu'un vrai trafic arrive ; permettrait aussi des sondes
  Kubernetes fiables, donc un rollback automatique réellement déclenché.
- **Déploiement progressif** (blue/green, canary) — limite le rayon d'impact d'une
  régression, mais suppose une infrastructure plus mature.
- **Infrastructure as Code** (Terraform, Ansible) — aujourd'hui le cluster est
  supposé préexistant ; le décrire en code le rendrait reproductible.
- **Renovate / Dependabot** — mise à jour automatisée des dépendances, complément
  naturel du SCA : détecter une CVE sert peu si personne ne met à jour.
- **Génération automatique du changelog** — directement exploitable, puisque les
  Conventional Commits sont déjà en place.
