# Les scripts d'automatisation

Le dossier `scripts/` regroupe les scripts Bash et Python qui portent la logique
du pipeline : construire et scanner les images, vérifier la qualité, publier une
version, déployer, mesurer. Le YAML de `.gitlab/ci/` ne fait que les appeler. Un
script se lance aussi à la main, se relit avec ShellCheck et se teste sans
cluster ni registry.

Chaque fiche ci-dessous donne le but du script, son fonctionnement, ses
paramètres, ses codes de sortie et ses conditions d'exécution. L'aide complète
de chaque script s'affiche avec `--help`.

## Principes communs

- **Gestion des erreurs** : en Bash, `set -euo pipefail` arrête le script à la
  première erreur ; en Python, les erreurs sont attrapées et traduites en codes
  de sortie distincts.
- **Codes de sortie** : `0` succès, `1` erreur de configuration ou technique, `2`
  (ou `3` pour un déploiement) quand le contrôle lui-même conclut à un échec. Un
  job distingue ainsi « l'outil n'a pas pu répondre » de « la réponse est non ».
- **Secrets** : mots de passe et jetons viennent toujours de variables
  d'environnement, jamais du code, et ne sont jamais affichés dans les journaux.
- **Pas de doublons** : journalisation et vérifications communes aux scripts
  Bash sont dans `lib/common.sh`.
- **Aucune installation** pour les scripts Python : bibliothèque standard seule.
- **Contrôles en CI** : ShellCheck sur tous les scripts Bash (job `shellcheck`),
  suite de tests à chaque commit (job `test-scripts`, voir
  [Les tests](#les-tests)).

## Organisation des fichiers

```
scripts/
├── lib/
│   └── common.sh            # fonctions communes (logs, vérifs, retry)
├── ci/
│   ├── build_and_push.sh    # construit une image Docker, la scanne, puis l'envoie au registry
│   ├── trivy_scan.sh        # scan Trivy bloquant qui garde un rapport JSON et un tableau
│   ├── promote_image.sh     # pose le numéro de version SemVer sur une image déjà construite
│   ├── check_version.sh     # vérifie que les versions du dépôt suivent le tag de release
│   ├── release_notes.sh     # écrit la description de la Release GitLab d'une version
│   ├── terraform_check.sh   # valide, planifie ou applique les environnements Terraform
│   ├── ansible_check.sh     # contrôle le projet Ansible (syntaxe puis lint)
│   ├── notify.py            # annonce le résultat d'une étape sur un webhook d'équipe
│   ├── collect_dora.py      # calcule les quatre indicateurs DORA depuis l'API GitLab
│   ├── collect_security.py  # indexe les rapports de sécurité dans Elasticsearch
│   ├── quality_gate.py      # vérifie le Quality Gate SonarCloud
│   └── check_coverage.py    # vérifie le taux de couverture des tests
├── deploy/
│   ├── deploy.sh            # déploie sur Kubernetes (avec retour arrière auto)
│   └── rollback.sh          # revient en arrière sur Kubernetes
├── monitoring/
│   └── install_alerting.py  # installe les règles d'alerte Kibana et leur clé de chiffrement
├── docs/
│   └── build_pdf.sh         # produit les PDF balisés des livrables
└── tests/
    ├── run_tests.sh         # teste tous les scripts ci-dessus
    ├── validate_k8s.sh      # valide les manifestes k8s/ et le chart helm/ (sans cluster)
    ├── run_k6.sh            # lance les tests de performance k6
    ├── check_accessibilite_docs.py  # contrôle l'accessibilité des documents livrables
    ├── fixtures/            # faux rapports JaCoCo et de sécurité, réponses d'API GitLab
    └── stubs/               # faux kubectl / docker / trivy / k6 / terraform / ansible
```

Les scénarios de performance ne sont pas dans `scripts/` mais dans `tests/k6/`
(voir [QUALITY.md](QUALITY.md) §5) : ce sont des tests de l'application, pas des
outils du pipeline.

| Script                              | Job(s) qui l'exécutent                                      |
| ----------------------------------- | ----------------------------------------------------------- |
| `ci/build_and_push.sh`              | `package-back`, `package-front`                             |
| `ci/trivy_scan.sh`                  | `trivy-fs`, et `package-*` via `build_and_push.sh`          |
| `ci/promote_image.sh`               | `promote-back`, `promote-front` (pipeline de tag)           |
| `ci/check_version.sh`               | `version-consistency` (pipeline de tag)                     |
| `ci/release_notes.sh`               | `release` (pipeline de tag)                                 |
| `ci/terraform_check.sh`             | `terraform-validate`, `terraform-plan`, `terraform-apply-*` |
| `ci/ansible_check.sh`               | `ansible-lint`                                              |
| `ci/notify.py`                      | `.deploy_template` (`after_script`), `notify-echec`         |
| `ci/collect_dora.py`                | `dora-metrics`                                              |
| `ci/quality_gate.py`                | `quality-gate`                                              |
| `ci/check_coverage.py`              | `coverage-gate`                                             |
| `deploy/deploy.sh`                  | `deploy-staging`, `deploy-production`                       |
| `deploy/rollback.sh`                | `rollback-production`                                       |
| `tests/run_tests.sh`                | `test-scripts`                                              |
| `tests/validate_k8s.sh`             | `lint-k8s`, `lint-helm`                                     |
| `tests/run_k6.sh`                   | aucun (les jobs `k6-*` appellent k6 directement)            |
| `ci/collect_security.py`            | aucun : lancé depuis un poste                               |
| `monitoring/install_alerting.py`    | aucun : lancé depuis un poste                               |
| `docs/build_pdf.sh`                 | aucun : lancé depuis un poste                               |
| `tests/check_accessibilite_docs.py` | aucun : lancé depuis un poste                               |

---

## `lib/common.sh`

**But.** Fichier de fonctions partagées. Il ne se lance pas : les autres
scripts Bash le chargent au début (`source …/lib/common.sh`).

**Contenu.** `log_info`, `log_warn`, `log_error` (sur la sortie d'erreur, en
couleur seulement dans un vrai terminal) ; `die <message>` (affiche et sort en
`1`) ; `require_cmd <cmd…>` et `require_env <VAR…>` (arrêtent le script en
nommant ce qui manque) ; `retry <n> <délai> <cmd…>` (réessaie une commande
`n` fois). Il active aussi `set -euo pipefail`.

---

## `ci/build_and_push.sh`

**But.** Construire une image Docker et l'envoyer au registry. Il pose deux
tags : le SHA du commit (fixe) et un tag mobile (`latest` par défaut). Avec
`--scan`, il passe l'image à Trivy **avant** de la pousser.

**Pourquoi « scan, puis push ».** `promote_image.sh` ne demande que l'existence
du tag du SHA au registry. Si l'image était poussée avant d'être scannée, un tag
de release posé sur ce commit pourrait promouvoir une image que la porte a
refusée. Une image refusée, ou qu'on n'a pas pu scanner, n'atteint donc pas le
registry. Le scan est délégué à [`trivy_scan.sh`](#citrivy_scansh), qui en garde
un relevé.

**Paramètres.** `--context`, `--image`, `--tag` (obligatoires), `--moving-tag`
(défaut `latest`), `--dockerfile`, `--scan`, et pour le scan : `--scan-severity`
(défaut `HIGH,CRITICAL`), `--scan-report` (défaut `reports/trivy-image.json`),
`--trivy-image` (lance Trivy par `docker run`).

**Conditions d'exécution.** `docker` et un démon joignable (en CI : Docker in
Docker, runner privilégié). Variables `REGISTRY_HOST`, `REGISTRY_USER`,
`REGISTRY_PASSWORD`.

**Codes de sortie.** `0` ok ; `1` problème de configuration ou d'exécution, scan
impossible compris ; `2` image trop vulnérable, push annulé.

```bash
REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
scripts/ci/build_and_push.sh -c ./back -i "$CI_REGISTRY_IMAGE/back" -t "$CI_COMMIT_SHORT_SHA" \
  --scan --scan-report reports/trivy-image-back.json --trivy-image "$TRIVY_IMAGE"
```

---

## `ci/trivy_scan.sh`

**But.** Lancer un scan Trivy **bloquant** et en garder une trace : un rapport
JSON, et le tableau lisible à côté (même nom, extension `.txt`). Le constat
reste lisible dans les artefacts du job, et pas seulement dans son journal.

**Fonctionnement : deux passages.** Le premier est le _relevé_ (`--format json`,
sans porte) ; le second est la _porte_ (tableau, code de sortie bloquant). Dans
les jobs `package-*`, Trivy tourne dans un conteneur lancé par `docker run`
contre un démon dind : le JSON en sort par la sortie standard, qui marche
partout, là où un fichier demanderait un montage dépendant du runner. Le second
passage réutilise la base et l'analyse en cache.

**Le relevé ne masque jamais la porte.** Le code de sortie est celui du second
passage. Si le relevé échoue, c'est une erreur technique (`1`) et **aucun
rapport n'est écrit** : un fichier vide ne doit pas passer pour « zéro faille ».
Quand la porte se ferme, les deux fichiers existent quand même.

Le rapport est filtré **comme la porte** (mêmes sévérités, même fichier
d'exclusions) : il décrit ce que la porte a vu, pas tout ce que Trivy sait. Un
constat `MEDIUM` n'y figure pas.

**Paramètres.** `--mode` (`fs` ou `image`), `--target`, `--report` (tous
obligatoires ; le rapport doit finir par `.json`), `--severity` (défaut
`HIGH,CRITICAL`), `--scanners`, `--ignorefile`, `--docker-image` (lance Trivy
par `docker run` ; réservé au mode `image`, sans `--ignorefile`, puisque rien du
dépôt n'est monté dans ce conteneur).

**Conditions d'exécution.** `trivy` dans le `PATH`, ou `docker` avec
`--docker-image`. Accès réseau pour télécharger la base de vulnérabilités.

**Codes de sortie.** `0` aucun constat bloquant ; `1` problème de configuration
ou scan impossible ; `2` au moins un constat, la porte est fermée.

```bash
scripts/ci/trivy_scan.sh -m fs -T . -r reports/trivy-fs.json \
  --scanners vuln,secret,misconfig --ignorefile .trivyignore.yaml
scripts/ci/trivy_scan.sh -m image -T "$IMAGE:$CI_COMMIT_SHORT_SHA" \
  -r reports/trivy-image-back.json --docker-image "$TRIVY_IMAGE"
```

Les trois rapports sont publiés en artefacts, y compris quand le job échoue. Ces
noms sont une interface : `collect_security.py` les lit.

| Job             | Rapport JSON                     | Tableau                         |
| --------------- | -------------------------------- | ------------------------------- |
| `trivy-fs`      | `reports/trivy-fs.json`          | `reports/trivy-fs.txt`          |
| `package-back`  | `reports/trivy-image-back.json`  | `reports/trivy-image-back.txt`  |
| `package-front` | `reports/trivy-image-front.json` | `reports/trivy-image-front.txt` |

**Non fait** : le rapport au format GitLab (`reports: container_scanning`). Il
demanderait un troisième passage, pour un affichage que GitLab réserve à l'offre
Ultimate.

---

## `ci/promote_image.sh`

**But.** Poser un numéro de version SemVer sur une image **déjà construite et
déjà poussée** : il la tire du registry, lui ajoute le tag de version, la
repousse. Il ne construit rien.

**Pourquoi.** Deux builds du même commit ne produisent pas les mêmes couches :
reconstruire au moment du tag donnerait une image qui n'est plus celle que les
scans et k6 ont éprouvée. En retaguant, `back:1.0.1` et `back:08a216b0` ont le
même digest.

**Contrôles.** Il refuse ce qui n'est pas du SemVer (`v1.4`, `latest`, `v01.4.0`
avec un zéro de tête) et les métadonnées de build `+…`, qu'un tag Docker
n'accepte pas. Si l'image source est absente du registry, il échoue en le
disant : on ne publie pas un numéro de version qui ne désigne aucun artefact.

**Paramètres.** `--image`, `--from-tag`, `--version` (obligatoires).

**Conditions d'exécution.** `docker` et un démon joignable. Variables
`REGISTRY_HOST`, `REGISTRY_USER`, `REGISTRY_PASSWORD`. En CI, uniquement sur un
pipeline de tag. Voir [RELEASE.md](RELEASE.md) §2.1.

**Codes de sortie.** `0` image promue ; `1` paramètre invalide, version non
SemVer, image source absente ou échec du registry.

```bash
REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
scripts/ci/promote_image.sh -i "$CI_REGISTRY_IMAGE/back" \
  -f "$CI_COMMIT_SHORT_SHA" -v "$CI_COMMIT_TAG"
```

---

## `ci/check_version.sh`

**But.** Vérifier que le numéro de version déclaré dans le dépôt correspond au
tag de release. Trois fichiers sont contrôlés : `front/package.json` (version du
front), `back/build.gradle` (version du jar) et l'`appVersion` de
`helm/microcrm/Chart.yaml` (version de l'application déployée).

**Hors périmètre, délibérément.** Le `package.json` de la racine décrit
l'outillage du dépôt (hooks, commitlint, Prettier) et porte un autre nom,
`microcrm-tooling`. Le champ `version` du chart est la version du chart, que la
convention Helm distingue de celle de l'application.

**Fonctionnement.** Il rapporte **toutes** les divergences, pas seulement la
première, et un champ renommé le fait échouer au lieu de passer sur une chaîne
vide.

**Paramètres.** `--version` (obligatoire, avec ou sans « v »).

**Conditions d'exécution.** Bash et les outils de base, aucun accès réseau. En
CI, job `version-consistency`, à l'étape `lint` d'un pipeline de tag : une
divergence se voit avant de construire et de scanner.

**Codes de sortie.** `0` concordance ; `1` erreur de configuration ; `2` au
moins une divergence.

```bash
scripts/ci/check_version.sh --version "$CI_COMMIT_TAG"
```

---

## `ci/release_notes.sh`

**But.** Écrire la description de la Release GitLab d'une version : le commit,
le pipeline, et pour chaque image **ses deux tags**, le numéro de version et le
SHA. C'est leur égalité qui rend une version traçable.

**Fonctionnement.** Il ne crée pas la Release : c'est le mot-clé `release:` du
job qui le fait, une fois ce fichier écrit, en appelant `glab release create`
avec le jeton du job. Il n'interroge ni le registry ni l'API : il met en forme
ce que GitLab pose dans l'environnement. Une variable absente l'arrête sans
écrire de fichier, plutôt que de produire une Release qui annoncerait une image
vide.

**Paramètres.** Le fichier de sortie (obligatoire). Variables lues :
`CI_COMMIT_TAG`, `CI_COMMIT_SHA`, `CI_REGISTRY_IMAGE` (obligatoires),
`CI_COMMIT_SHORT_SHA`, `APP_BACK_NAME`, `APP_FRONT_NAME`, `CI_PIPELINE_URL`,
`CI_PROJECT_URL`.

**Conditions d'exécution.** Écrit en **sh POSIX** : l'image du job
(`$GLAB_IMAGE`, basée sur Alpine) n'a que busybox `sh`. En CI, job `release`,
sur un pipeline de tag et seulement après `promote-back` **et**
`promote-front`. Voir [RELEASE.md](RELEASE.md) §2.2.

**Codes de sortie.** `0` fichier écrit ; `1` paramètre ou variable manquante.

```bash
CI_COMMIT_TAG=v1.0.1 CI_COMMIT_SHA=$(git rev-parse HEAD) \
CI_REGISTRY_IMAGE=registry.gitlab.com/xxx \
scripts/ci/release_notes.sh reports/release-notes.md
```

---

## `ci/terraform_check.sh`

**But.** Contrôler, planifier ou appliquer les configurations Terraform de
`terraform/environments/`. Trois modes, qui n'ont ni le même coût ni la même
valeur de preuve :

| Mode                  | Ce qu'il fait                                                            | Où il tourne                                           |
| --------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------ |
| `--validate` (défaut) | `fmt -check`, puis `init -backend=false` et `validate` par environnement | job `terraform-validate`, sur toutes les branches      |
| `--plan`              | `init`, `plan -lock=false -out=plan.cache`, puis le résumé `plan.json`   | job `terraform-plan` : MR, `develop`, `main`, bloquant |
| `--apply`             | `init` puis `apply plan.cache` (à défaut : `apply -auto-approve`)        | jobs `terraform-apply-<env>`, manuels sur `main`       |

**`--validate` n'exige rien** : `-backend=false`, aucun état, aucun cluster. Il
est donc jouable sur n'importe quel runner et sur toutes les branches ; un test
de `run_tests.sh` garantit qu'il le reste.

**`--plan` et `--apply` exigent `$TF_STATE_BASE_URL`** et les identifiants
`TF_HTTP_USERNAME` / `TF_HTTP_PASSWORD` : ils lisent l'état partagé hébergé par
GitLab. Le script compose `TF_HTTP_ADDRESS` **par environnement** (un état
distinct et verrouillé pour chacun, voir [TERRAFORM.md](TERRAFORM.md) §4). Sans
cette adresse, il refuse de commencer en nommant la variable.

**Ce que `--plan` prouve.** Il compare le dépôt à ce qui existe réellement : une
modification faite à la main dans le cluster apparaît en dérive, et un « 0 to
add, 0 to change » est une information. Il ne prouve pas que l'`apply` passera :
un `Deployment` ne consomme aucun quota, seuls ses pods en consomment. Le script
le rappelle à l'exécution.

**`--apply` exige `-e <environnement>`.** Appliquer en boucle ferait passer la
production dans le même geste que le staging. L'obligation d'écrire
l'environnement visé remplace la confirmation interactive qu'on perd avec
`-auto-approve`.

**`--require-plan` : appliquer le plan relu, ou rien.** `--plan` enregistre son
plan dans `<env>/plan.cache` (publié en artefact) et `--apply` applique **ce
fichier**, pour que ce qui part en production soit ce qui a été approuvé en merge
request. Avec `--require-plan`, que passent les jobs de CI, l'absence de plan
enregistré est un **échec** : un artefact expiré ou un job relancé seul ne
dégrade pas la garantie en silence. Sans le drapeau (usage sur un poste),
Terraform replanifie avec un avertissement. Si l'état a bougé entre les deux,
Terraform refuse lui-même (« Saved plan is stale »).

**Rapport pour les merge requests.** `<env>/plan.json` contient trois entiers
(create/update/delete) ; leur somme est écrite dans `plan-global.json`, à la
racine des environnements. C'est ce fichier unique qui alimente le widget
Terraform des merge requests, parce que GitLab n'accepte qu'un fichier de
rapport par job. Ces résumés demandent `jq`, qui reste **facultatif** : absent,
le script prévient et continue. Le JSON complet du plan n'est jamais écrit sur
le disque.

**Autres comportements.** Les environnements sont **découverts**, jamais listés
en dur : un nouvel environnement est contrôlé sans toucher au script. Tous sont
traités même après un échec, pour que deux erreurs se lisent en une exécution.

**Paramètres.** `--validate`, `--plan`, `--apply` (exclusifs), `-e <nom>`
(restreint à un environnement ; obligatoire pour `--apply`), `--require-plan`
(avec `--apply`), `-d <répertoire>` (défaut `terraform/environments`, ou
`$TERRAFORM_ENVS_DIR`).

**Conditions d'exécution.** `terraform` (et `jq`, facultatif). Pour `--plan` et
`--apply`, l'accès à l'état partagé et au cluster (en CI : l'agent GitLab).

**Codes de sortie.** `0` tous les environnements passent ; `1` au moins un
échec ou une erreur de configuration.

```bash
scripts/ci/terraform_check.sh                       # validate, hors cluster
scripts/ci/terraform_check.sh --plan
scripts/ci/terraform_check.sh --apply -e production
```

Le détail des ressources est dans [TERRAFORM.md](TERRAFORM.md).

---

## `ci/ansible_check.sh`

**But.** Contrôler le projet Ansible : `--syntax-check` du playbook, puis
`ansible-lint`.

**Pourquoi un script.** `ansible/ansible.cfg` n'est lu que si le répertoire
courant est `ansible/` : un `ansible-lint ansible/` lancé depuis la racine
l'ignore en silence, tourne sans inventaire ni configuration du projet, et sort
en `0`. Le script entre donc dans le répertoire avant d'agir ; les stubs le
vérifient en journalisant leur répertoire courant. Les échecs sont cumulés : une
erreur de syntaxe n'escamote pas le lint.

**Paramètres.** `-d, --dir` (répertoire Ansible, ou `$ANSIBLE_DIR`),
`--collections` (installe d'abord les collections de `requirements.yml`).

**Conditions d'exécution.** `ansible` et `ansible-lint` (versions figées par
`ANSIBLE_VERSION` et `ANSIBLE_LINT_VERSION` en CI). Aucun accès au cluster.

**Codes de sortie.** `0` tout passe ; `1` au moins un contrôle a échoué, ou un
prérequis manque.

```bash
scripts/ci/ansible_check.sh
scripts/ci/ansible_check.sh --collections
```

Le périmètre des rôles est dans [ANSIBLE.md](ANSIBLE.md).

---

## `ci/notify.py`

**But.** Annoncer le résultat d'une étape du pipeline sur un canal d'équipe :
tout ce qui accepte un webhook JSON (Slack, Mattermost, Discord). Un déploiement
raté se voit sans ouvrir GitLab.

**Ce qui est notifié.** Les déploiements, succès comme échec, par
l'`after_script` de `.deploy_template`. Le reste du pipeline, en cas d'échec
seulement, par le job `notify-echec`. Un canal qui annonce chaque pipeline vert
devient un canal qu'on n'ouvre plus.

**Deux règles qui protègent le pipeline.**

- **Webhook absent : rien à faire, et surtout pas un échec.** Le script sort en
  `0` et écrit le message dans le journal du job. Un dépôt cloné sans la
  variable ne voit pas tous ses pipelines rougir.
- **Un envoi qui échoue ne fait jamais échouer le pipeline.** Un canal
  indisponible ne dit rien sur la qualité du déploiement.

**Paramètres.** `--statut` et `--sujet` (obligatoires), `--detail`, `--dry-run`.

**Conditions d'exécution.** Python 3. Variable `NOTIFY_WEBHOOK_URL`, facultative
et jamais dans le dépôt.

**Codes de sortie.** `0` dans tous les cas d'envoi (réussi, raté ou sans
webhook) ; `2` erreur d'utilisation.

```bash
scripts/ci/notify.py --statut "$CI_JOB_STATUS" --sujet "Déploiement production"
```

---

## `ci/collect_dora.py`

**But.** Calculer les quatre indicateurs DORA à partir de l'historique des
pipelines GitLab, et les sortir en JSON : fréquence de déploiement, délai de mise
en production, temps de rétablissement, taux d'échec des changements.

**Règle centrale : un indicateur qu'on ne peut pas mesurer vaut `null`,
accompagné de sa raison, jamais `0`.** Un `0` se lit comme une performance.

**Fonctionnement.** Il lit la liste des pipelines, puis les jobs de chacun, et
repère les déploiements et les retours arrière par leur **nom de job** (l'API
`/deployments` exige un jeton même sur un projet public).

| Indicateur   | Calcul                                                                       |
| ------------ | ---------------------------------------------------------------------------- |
| Fréquence    | déploiements réussis ÷ durée de la fenêtre                                   |
| Délai        | médiane de (fin du déploiement réussi − date du commit de tête)              |
| MTTR         | médiane de (fin du déploiement réussi − fin du premier échec de la série)    |
| Taux d'échec | tentatives ratées ÷ tentatives ; une réussite suivie d'un rollback est ratée |

Une tentative est un job de déploiement **réellement exécuté** (`success` ou
`failed`) : un job `manual` jamais déclenché n'est pas un déploiement, et un job
`canceled` n'est pas compté. Les événements retenus sont recopiés dans le JSON,
pour que chaque chiffre se vérifie à la main.

**Paramètres.** `--project` (id ou chemin, défaut `84606666`), `--host` (défaut
`https://gitlab.com`), `--token` (sinon `$GITLAB_TOKEN`), `--days` (fenêtre
glissante, défaut 30 ; `0` = tout l'historique), `--deploy-jobs` (défaut
`deploy-staging,deploy-production`), `--rollback-jobs` (défaut
`rollback-production`), `--output` (sinon la sortie standard),
`--elasticsearch` et `--es-index` (envoi en `_bulk`, défaut `microcrm-dora`),
`--fixtures` (rejoue des réponses d'API enregistrées au lieu du réseau).

**Conditions d'exécution.** Python 3 et un accès réseau à l'API GitLab. Le jeton
est **facultatif** tant que le projet est public ; fourni, il part dans
l'en-tête `PRIVATE-TOKEN` et n'est ni affiché ni recopié. Le mode `--fixtures`
n'a besoin ni de jeton ni de réseau : c'est celui des tests.

**Codes de sortie.** `0` collecte terminée, **même si des indicateurs sont
`null`** ; `1` erreur technique (réseau, API en erreur, fixtures illisibles,
écriture impossible, envoi Elasticsearch refusé).

```bash
scripts/ci/collect_dora.py --days 30 --output reports/dora.json
scripts/ci/collect_dora.py --fixtures scripts/tests/fixtures --days 0
scripts/ci/collect_dora.py --days 0 --elasticsearch http://127.0.0.1:9200
```

**Le job `dora-metrics`** (`.gitlab/ci/deploy.yml`) tourne sur `develop`, `main`
et les tags, et publie `reports/dora.json` en artefact pendant 30 jours.

- **Il ne fait jamais rougir le pipeline** (`allow_failure: true`) : une mesure
  impossible (API lente, quota de requêtes anonymes) ne dit rien de ce qui est
  livré. Aucun artefact n'est alors publié : un fichier absent, pas un fichier
  faux.
- **Il lit l'historique tel qu'il est au démarrage du pipeline** (`needs: []`).
  Le déploiement que ce pipeline permettra apparaît à la collecte suivante : les
  jobs `deploy-*` sont manuels et ne peuvent pas être attendus.
- **Il n'alimente pas Elasticsearch**, qui vit dans le cluster sans adresse
  joignable depuis un job. Le tableau de bord est alimenté depuis un poste (voir
  [MONITORING.md](MONITORING.md)).

| Date            | Exécution                                                    | Résultat                                    |
| --------------- | ------------------------------------------------------------ | ------------------------------------------- |
| 2026-10-03 à 05 | En CI, pipelines #2909284076, #2912362926, #2913490784       | artefact `reports/dora.json` publié et relu |
| 2026-10-05      | Depuis un poste, fenêtre de 30 jours, après la release 1.0.1 | 67 pipelines, 15 tentatives dont 8 réussies |

---

## `ci/collect_security.py`

**But.** Transformer les rapports des scanners de sécurité en documents
Elasticsearch, pour le tableau de bord Kibana « sécurité » : un document
`constat` par vulnérabilité, misconfiguration ou secret, un document `scan` par
rapport lu, un document `exception` par entrée de `.trivyignore.yaml`.

**Règle : l'absence de donnée n'est pas un zéro.** Un rapport lu sans constat
produit un `scan` à `total: 0`, qui est une mesure. Un rapport non fourni ne
produit rien. Un rapport illisible fait échouer le script.

**Il ne juge pas.** Il ne sort jamais en erreur parce qu'il y a des
vulnérabilités : la porte reste `trivy_scan.sh`, dans les jobs `trivy-fs` et
`package-*`.

**Sources lues.** Les rapports publiés par ces jobs (`reports/trivy-fs.json`,
`reports/trivy-image-back.json`, `reports/trivy-image-front.json`) et le rapport
JSON de Dependency-Check (`back/build/reports/dependency-check-report.json`,
produit parce que `formats` contient `'JSON'` dans `back/build.gradle`).

**Limite à connaître.** Les rapports publiés par la CI sont filtrés comme la
porte : HIGH et CRITICAL seulement, exclusions appliquées. Collectés tels quels,
ils donnent `0` constat MEDIUM ou LOW (non demandés, pas absents) et `0` constat
excepté (Trivy les retire avant d'écrire). Le document `scan` ne distingue pas
ces deux régimes. Pour un tableau complet, collecter des scans sans filtre
rejoués sur un poste.

**Paramètres.** `--trivy-report` et `--dependency-check-report` (répétables),
`--optional` (un rapport introuvable est signalé puis ignoré), `--trivyignore` /
`--no-trivyignore`, `--commit`, `--ref`, `--date`, `--output`,
`--elasticsearch`, `--es-index` (défaut `microcrm-security`).

**Conditions d'exécution.** Python 3, bibliothèque standard. Aucun job ne
l'exécute : il se lance depuis un poste, sur les artefacts téléchargés, avec un
`port-forward` vers Elasticsearch.

**Codes de sortie.** `0` collecte terminée, même sans aucun constat ; `1` erreur
technique (aucune source, rapport introuvable sans `--optional`, rapport
invalide, fichier d'exceptions illisible, `--date` illisible, envoi
Elasticsearch raté).

```bash
scripts/ci/collect_security.py \
  --trivy-report reports/trivy-fs.json \
  --trivy-report reports/trivy-image-back.json \
  --dependency-check-report back/build/reports/dependency-check-report.json \
  --optional --elasticsearch http://127.0.0.1:9200
```

**Non vérifié** : la lecture d'un rapport Dependency-Check réel. Les tests
s'appuient sur les fixtures fabriquées de `scripts/tests/fixtures/security/`
(décrites dans leur `README.md`).

---

## `monitoring/install_alerting.py`

**But.** Installer l'alerting de la supervision : le modèle de l'index
`microcrm-alerts` dans Elasticsearch, puis les règles d'alerte Kibana décrites
par les fichiers de `k8s/elk/alerting/rules/`.

**Pourquoi.** Une règle créée à la souris vit dans l'index `.kibana` d'un pod et
disparaît avec lui, sans prévenir. Ici la règle est un fichier versionné, et ce
script est la seule façon prévue de la faire exister dans une instance.

**Fonctionnement.** Un fichier JSON par règle ; le nom du fichier est
l'identifiant de la règle dans Kibana, et son contenu le corps attendu par
`POST /api/alerting/rule/<id>`. Cet identifiant fixe rend le script idempotent :
règle absente, création (`POST`) ; règle présente, mise à jour sur place
(`PUT`). Deux exécutions successives donnent « 8 règles créées » puis « 8 règles
mises à jour », huit au total (vérifié le 2026-10-02).

| Mode        | Ce qu'il fait                                                                                      | À qui il parle          |
| ----------- | -------------------------------------------------------------------------------------------------- | ----------------------- |
| sans option | Installe le modèle d'index, puis crée ou met à jour chaque règle                                   | Kibana et Elasticsearch |
| `--secret`  | Crée le Secret `kibana-encryption-key` (valeur aléatoire) s'il n'existe pas, puis redémarre Kibana | `kubectl`               |
| `--dry-run` | Relit et contrôle les fichiers de règles, sans aucun appel réseau (mode des tests)                 | personne                |
| `--etat`    | Affiche l'état de chaque règle : activée, dernière exécution, alerte active. Ne modifie rien       | Kibana                  |

**Pourquoi `--secret` est un mode à part.** Redémarrer Kibana coupe le
`port-forward` par lequel on lui parle : un script qui ferait les deux d'un
trait échouerait toujours à la seconde moitié. La clé n'est écrite que dans le
Secret ; elle est envoyée à `kubectl` par l'entrée standard, jamais en argument
(un argument se lit dans `ps`).

**Paramètres.** Les quatre modes ci-dessus (exclusifs), `--regles <dossier>`.
Variables : `KIBANA_URL` (défaut `http://127.0.0.1:5601`), `ELASTICSEARCH_URL`
(défaut `http://127.0.0.1:9200`), `LOGGING_NAMESPACE` (défaut `logging`, mode
`--secret`).

**Conditions d'exécution.** Python 3, bibliothèque standard. Hors `--dry-run`,
deux `port-forward` ouverts vers Kibana et Elasticsearch ; pour `--secret`, un
`kubectl` qui vise le cluster. Le script **refuse d'installer** tant que Kibana
n'a pas de clé de chiffrement permanente, et dit quoi lancer. Aucun job ne
l'exécute.

**Codes de sortie.** `0` tout est en place (en `--dry-run`, tous les fichiers
sont valides) ; `1` fichier de règle invalide, Kibana ou Elasticsearch
injoignable, clé de chiffrement manquante, ou appel refusé ; `2` erreur
d'utilisation.

```bash
scripts/monitoring/install_alerting.py --secret     # une fois par cluster
kubectl apply -k k8s/elk -n logging                 # les connecteurs préconfigurés
scripts/monitoring/install_alerting.py              # crée ou met à jour les règles
scripts/monitoring/install_alerting.py --etat
```

**Non vérifié** : la création réelle du Secret par `--secret` sur un cluster qui
n'en a pas. Seuls la branche « le Secret existe déjà » et le chemin complet
contre le faux `kubectl` sont éprouvés. Le détail des règles est dans
`k8s/elk/alerting/README.md` et [MONITORING.md](MONITORING.md) §11.

---

## `docs/build_pdf.sh`

**But.** Produire les PDF des livrables à partir de leur source Markdown, en
passant par un HTML accessible, avec une mise en page identique d'un document à
l'autre.

**Pourquoi un PDF « balisé ».** Un PDF ordinaire est une suite de glyphes : un
lecteur d'écran y lit du texte sans savoir ce qui est un titre, un tableau ou
une image. Un PDF balisé embarque l'arbre de structure du document et sa
langue. Chrome le produit à partir de la structure du HTML : c'est donc le HTML
que soigne le script.

**Fonctionnement**, pour chaque document : chaque bloc Mermaid est remplacé par
une image dont le texte alternatif vient de `accTitle` / `accDescr`, ou à défaut
du titre de la section ; les schémas sont rendus par `mermaid-cli` ; le Markdown
est converti par `marked` et enveloppé dans une page qui déclare `lang="fr"`, un
titre et une feuille d'impression ; Chrome headless imprime le PDF, signets
compris ; enfin le script **vérifie** le fichier produit (arbre de structure,
marquage, langue, signets) et échoue s'il en manque un.

**Paramètres.** `-o, --output-dir` (défaut : à côté de chaque source), `-w,
--work-dir` (fichiers intermédiaires ; défaut : répertoire temporaire supprimé),
`--format svg|png` (défaut `svg`), `--html-only` (s'arrête au HTML, demande
`-w`). Sans argument, il traite les cinq livrables de `docs/`. Variables :
`CHROME_BIN`, `MARKED_VERSION` (16.4.2), `MERMAID_CLI_VERSION` (11.17.0) : les
versions sont figées pour qu'un rendu ne change pas tout seul.

**Conditions d'exécution.** `npx` (donc Node), et Chrome ou Chromium. Pas
d'exécution en CI, pas de test dans `run_tests.sh`. Les PDF de `docs/` sont
produits par ce script (`pdfinfo` : `Tagged: yes`).

**Codes de sortie.** `0` ok ; `1` problème de configuration ou d'exécution ; `4`
un PDF produit n'est pas balisé.

```bash
scripts/docs/build_pdf.sh                                  # les cinq livrables
scripts/docs/build_pdf.sh -o /tmp/pdf docs/plan-optimisation-release.md
```

---

## `tests/check_accessibilite_docs.py`

**But.** Contrôler mécaniquement l'accessibilité des documents livrables en
Markdown : la part du RGAA 4.1 et des WCAG 2.1 qui se vérifie à la machine, et
elle seule. La justesse d'un texte alternatif ou la clarté d'une phrase
demandent une relecture humaine.

**Ce qu'il contrôle.** Un seul titre de niveau 1 et aucun saut de niveau ; un
texte alternatif non vide, qui ne soit pas un nom de fichier, sur chaque image ;
une ligne d'en-tête sans cellule vide sur chaque tableau ; aucun lien libellé
« ici » ou « cliquez ici » ; un texte à proximité de chaque schéma Mermaid ;
aucun pictogramme qui porte seul une information. Il **signale** sans en faire
un défaut les phrases de plus de 60 mots.

**Paramètres.** Les fichiers à contrôler (sans argument : les cinq livrables de
`docs/` et `RELEASE.md`), `--strict` (les phrases longues deviennent des
défauts), `--max-mots N` (seuil), `--quiet`.

**Conditions d'exécution.** Python 3, bibliothèque standard. Branché sur aucun
job. Il ne vérifie ni la langue du document (rôle de `build_pdf.sh`), ni le
contraste des schémas rendus, ni le développement des sigles.

**Codes de sortie.** `0` aucun défaut ; `1` au moins un défaut ; `2` erreur
d'usage ou fichier introuvable.

```bash
python3 scripts/tests/check_accessibilite_docs.py            # les six livrables
python3 scripts/tests/check_accessibilite_docs.py MONITORING.md
```

---

## `ci/quality_gate.py`

**But.** Demander à SonarCloud si le Quality Gate d'un projet est passé, et
faire échouer le job sinon.

**Fonctionnement.** L'analyse Sonar est asynchrone : le script interroge l'API à
intervalle régulier (`--poll`) jusqu'à obtenir le statut, ou jusqu'au délai
maximal (`--timeout`). En échec, il affiche les conditions non tenues.

**Paramètres.** `--project-key` (obligatoire), `--host` (défaut
`https://sonarcloud.io`), `--branch`, `--timeout` (défaut 300 s), `--poll`
(défaut 10 s).

**Conditions d'exécution.** Python 3, accès réseau au serveur Sonar, variable
`SONAR_TOKEN` (jamais affichée). En CI, le job `quality-gate` l'appelle deux
fois, pour le back et pour le front, après `sonar-back` et `sonar-front`.

**Codes de sortie.** `0` Quality Gate OK ; `1` problème technique (réseau,
jeton, délai dépassé) ; `2` Quality Gate en échec.

```bash
SONAR_TOKEN=$SONAR_TOKEN scripts/ci/quality_gate.py --host "$SONAR_HOST_URL" \
  --project-key "$SONAR_PROJECT_KEY_BACK" --branch "$CI_COMMIT_REF_NAME"
```

---

## `ci/check_coverage.py`

**But.** Lire le rapport de couverture JaCoCo du back et échouer si la couverture
est sous un seuil. C'est un contrôle rapide, hors ligne, indépendant de Sonar.

**Paramètres.** `--report` (obligatoire), `--min` (défaut 80 ; la CI passe
`$COVERAGE_MIN`, fixé à 90), `--counter` (`LINE` par défaut, ou `INSTRUCTION`,
`BRANCH`, `METHOD`, `CLASS`, `COMPLEXITY`).

**Conditions d'exécution.** Python 3 et le rapport XML produit par
`./gradlew test jacocoTestReport`. En CI, job `coverage-gate`, après
`test-back`.

**Codes de sortie.** `0` seuil respecté ; `1` erreur (fichier absent, XML
invalide) ; `2` couverture trop basse.

```bash
scripts/ci/check_coverage.py \
  --report back/build/reports/jacoco/test/jacocoTestReport.xml --min 90
```

---

## `deploy/deploy.sh`

**But.** Déployer une image sur un Deployment Kubernetes, et revenir de lui-même
à la version précédente si le déploiement n'aboutit pas.

**Fonctionnement.** Il vérifie que le Deployment existe, pose l'image
(`kubectl set image`), attend la fin du rollout (`kubectl rollout status`, avec
un délai maximal) et, en cas d'échec ou de dépassement, lance `kubectl rollout
undo` puis sort en erreur. En CI, l'overlay Kustomize appliqué juste avant porte
déjà la bonne image : le `set image` ne crée alors aucune révision
supplémentaire, et le script sert pour l'attente et le retour arrière. Voir
[RELEASE.md](RELEASE.md).

**Paramètres.** `--namespace`, `--deployment`, `--container`, `--image`
(obligatoires), `--timeout` (défaut `180s` ; la CI passe `$DEPLOY_TIMEOUT`),
`--no-auto-rollback`.

**Conditions d'exécution.** `kubectl` et la variable `KUBECONFIG`. En CI, elle
est injectée par l'agent GitLab pour Kubernetes ; sur un poste, l'exporter
(`export KUBECONFIG=~/.kube/config`).

**Codes de sortie.** `0` déploiement réussi ; `1` problème de configuration
(option, outil ou Deployment manquant) ; `3` déploiement raté, retour arrière
lancé.

```bash
scripts/deploy/deploy.sh -n microcrm-staging -d back -c back \
  -i "$CI_REGISTRY_IMAGE/back:$CI_COMMIT_SHORT_SHA" -t 180s
```

---

## `deploy/rollback.sh`

**But.** Revenir à la révision précédente d'un Deployment, ou à une révision
précise, quand une version déployée pose problème.

**Fonctionnement.** `kubectl rollout undo` (vers la révision précédente, ou
`--to-revision`), puis attente de la fin du rollout et vérification.

**Paramètres.** `--namespace`, `--deployment` (obligatoires), `--to-revision`
(défaut : la révision précédente ; liste avec `kubectl rollout history`),
`--timeout` (défaut `180s`).

**Conditions d'exécution.** `kubectl` et `KUBECONFIG`, comme `deploy.sh`. Ne pas
l'enchaîner après un retour arrière automatique de `deploy.sh` : « la
précédente » serait alors la mauvaise version.

**Codes de sortie.** `0` révision rétablie ; `1` problème de configuration ; `3`
le rollback a échoué.

```bash
scripts/deploy/rollback.sh -n microcrm-production -d back
scripts/deploy/rollback.sh -n microcrm-production -d back --to-revision 7
```

---

## `tests/run_k6.sh`

**But.** Lancer un scénario de performance k6 (dossier `tests/k6/`). Il choisit
le bon fichier, écrit le rapport JSON au bon endroit et **traduit le code de
sortie de k6** (99 quand un seuil est dépassé, 107 quand le script plante) en
codes lisibles.

Toute la logique du test (charge, seuils, parcours) est dans les fichiers
`tests/k6/*.js`, pas dans le script : la commande locale et le job CI mesurent
la même chose.

**Paramètres.** `--scenario` (`smoke` par défaut, `load` ou `stress`), `--url`,
`--output-dir` (défaut `reports/k6`), `--no-report` ; tout ce qui suit `--` est
passé tel quel à k6.

**Conditions d'exécution.** `k6` installé et l'API démarrée (défaut
`http://localhost:8080`). Sans k6, passer par l'image Docker `grafana/k6` (voir
[README.md](README.md)).

**Codes de sortie.** `0` tout va bien ; `1` problème de configuration ; `2`
seuils de performance non tenus ; `3` le test n'a pas pu aller au bout (API
injoignable, k6 en erreur).

```bash
scripts/tests/run_k6.sh                             # smoke sur localhost:8080
scripts/tests/run_k6.sh --scenario load --url http://back:8080
K6_LOAD_VUS=25 scripts/tests/run_k6.sh -s load      # surcharger la charge
scripts/tests/run_k6.sh -s smoke -- --vus 3         # option passée à k6
```

Le détail des scénarios et des seuils est dans [QUALITY.md](QUALITY.md) §5.

---

## `tests/validate_k8s.sh`

**But.** Valider les manifestes Kubernetes de `k8s/` **sans cluster** : il
construit chaque overlay avec le Kustomize embarqué dans `kubectl`, puis vérifie
le rendu. Quand `helm` est disponible, il en fait autant du chart
`helm/microcrm/` et compare les deux rendus.

**Ce qu'il vérifie.**

- chaque overlay (`staging`, `production`) se construit ;
- les Deployments s'appellent `$APP_BACK_NAME` / `$APP_FRONT_NAME` **et portent
  un conteneur du même nom** : c'est le contrat de `deploy.sh`
  (`kubectl set image deployment/back back=…`). Un `namePrefix:` casse le
  premier, un renommage de conteneur le second, et aucun des deux ne fait
  échouer `kubectl apply` ;
- toute ConfigMap référencée par un Deployment existe dans le rendu (une
  référence morte n'échoue pas à l'`apply` : elle bloque le pod au démarrage) ;
- les sondes visent un port réellement déclaré par leur conteneur ;
- chaque conteneur porte `runAsNonRoot: true` et
  `allowPrivilegeEscalation: false`, contrôlés **au niveau conteneur**, parce
  qu'une valeur posée là écrase celle du pod ;
- aucune image en `latest` ni sans tag ;
- chaque Deployment référence le Secret de tirage d'images attendu
  (`$REGISTRY_SECRET_NAME`) : un nom qui diverge de celui que crée la CI laisse
  tous les pods en `ImagePullBackOff` sans erreur à l'`apply` ;
- aucun hôte d'Ingress en `.invalid` ne subsiste dans le rendu d'un overlay : la
  base n'en porte que de non résolvables, donc un `.invalid` qui survit signale
  un patch d'Ingress oublié (voir [K8S.md](K8S.md) §7) ;
- staging et production produisent des valeurs différentes (ConfigMap, hôte
  d'Ingress, ressources du back) : les patches d'overlay s'appliquent ;
- **le chart Helm passe les mêmes contrôles** (`helm template … -f
values-<env>.yaml`, étiquetés `helm/staging` et `helm/production`) ;
- **son rendu est identique à celui de l'overlay correspondant**, au seul label
  `app.kubernetes.io/managed-by` près. Deux descriptions de la même application
  sont deux occasions de diverger ; cette assertion rend la divergence visible
  ici plutôt qu'au déploiement. En cas d'écart, le script affiche les premières
  lignes divergentes sous forme de faits
  (`Kustomize seul : Deployment/back …limits.memory = 1Gi`).

**Quand `helm` est absent** (job `lint-k8s`, dont l'image `$KUBECTL_IMAGE` ne le
fournit pas), la section Helm est marquée `ignoré`, avec sa raison, et le bilan
compte les sections ignorées à part : ni succès, ni échec.

**`--autotest`** rejoue toutes ces assertions sur des rendus volontairement
abîmés (Deployment renommé, conteneur renommé, ConfigMap fantôme, sonde sur un
port inconnu, `runAsNonRoot` retiré, image en `latest`, pull secret absent ou
mal nommé…) et vérifie qu'elles **échouent**. L'assertion d'équivalence est
auto-testée dans les deux sens : elle doit tomber sur une divergence réelle et
rester silencieuse sur la seule différence légitime, `managed-by`.

**Paramètres.** `--autotest`. Variables (valeurs par défaut) :
`K8S_OVERLAYS_DIR` (`k8s/overlays`), `HELM_CHART_DIR` (`helm/microcrm`),
`APP_BACK_NAME` (`back`), `APP_FRONT_NAME` (`front`), `REGISTRY_SECRET_NAME`
(`gitlab-registry`) : les mêmes que celles du pipeline, pour que le contrat
vérifié soit celui que la CI déclare.

**Conditions d'exécution.** `kubectl` (et `helm`, facultatif), aucun cluster.
Écrit en **sh POSIX** : l'image `alpine/kubectl` n'a que busybox `sh`, et un job
de lint n'a pas à installer bash.

**Codes de sortie.** `0` tout passe ; `1` au moins une assertion échoue. Une
section ignorée ne change pas le code de sortie.

```bash
scripts/tests/validate_k8s.sh              # les assertions seules
scripts/tests/validate_k8s.sh --autotest   # + preuve qu'elles se déclenchent
```

| Exécution                                | Assertions               |
| ---------------------------------------- | ------------------------ |
| Poste avec `helm`, sans `--autotest`     | 151                      |
| Job `lint-helm` (`--autotest`, helm)     | 174                      |
| Job `lint-k8s` (`--autotest`, sans helm) | 98, section Helm ignorée |

Le recouvrement des deux jobs est assumé : chacun reste autonome. Le détail des
manifestes est dans [K8S.md](K8S.md), celui du chart dans [HELM.md](HELM.md).

---

## Les tests

Le job **`test-scripts`** (étape `test`, image `$PYTHON_IMAGE`, qui fournit bash
et python3) teste tous les scripts à chaque commit, dans un environnement
contrôlé, sans registry ni cluster.

**Comment on teste un script de déploiement sans cluster.** Les vraies commandes
`kubectl`, `docker`, `trivy`, `k6`, `terraform` et `ansible` sont remplacées par
de faux programmes (`scripts/tests/stubs/`) placés en tête du `PATH`. Ils notent
ce qu'on leur demande dans un fichier et renvoient le code de sortie que le test
veut. Le faux `trivy` reproduit le vrai sur le point qui compte : des constats
ne le font sortir en erreur que si `--exit-code` est passé, ce qui permet de
vérifier que le relevé et la porte sont deux passages distincts. On vérifie
ainsi :

- que chaque script renvoie le **bon code de sortie** dans chaque situation
  (paramètre manquant, secret absent, déploiement raté…) ;
- qu'il lance la **bonne commande** (par exemple `rollout undo` quand un
  déploiement échoue) ;
- qu'il **ne fait rien** quand il ne doit rien faire (pas de push si le build a
  raté ou si Trivy trouve une faille CRITICAL, pas de rollback si le déploiement
  a réussi) ;
- qu'aucun **secret n'apparaît dans les journaux**.

Les scripts Python sont testés sur des fixtures (`scripts/tests/fixtures/`) :
rapports JaCoCo, dont un XML cassé et un rapport vide, rapports de sécurité,
réponses d'API GitLab enregistrées. Le faux `k6` rejoue les cas qu'on ne peut
pas provoquer à la demande avec un vrai serveur : seuils dépassés, API
injoignable. Un dernier bloc vérifie des propriétés du pipeline qu'un lint ne
voit pas : artefacts publiés même en échec, Release conditionnée aux deux
promotions, mesure DORA non bloquante.

**430 assertions, toutes vertes** (mesuré le 2026-10-06) :

| Bloc                    | Assertions | Bloc                                 | Assertions |
| ----------------------- | ---------: | ------------------------------------ | ---------: |
| `lib/common.sh`         |          8 | `ci/collect_dora.py`                 |         16 |
| `ci/build_and_push.sh`  |         30 | `ci/collect_security.py`             |         56 |
| `ci/trivy_scan.sh`      |         33 | `ci/quality_gate.py`                 |          5 |
| `ci/promote_image.sh`   |         49 | `ci/check_coverage.py`               |         10 |
| `ci/check_version.sh`   |         18 | `deploy/deploy.sh`                   |         18 |
| `ci/release_notes.sh`   |         15 | `deploy/rollback.sh`                 |         11 |
| `ci/terraform_check.sh` |         59 | `monitoring/install_alerting.py`     |         33 |
| `ci/ansible_check.sh`   |         11 | `tests/run_k6.sh`                    |         21 |
| `ci/notify.py`          |         18 | pipeline : rapports, release, mesure |         19 |

```bash
# Lancer toute la suite (rien n'est construit ni déployé)
scripts/tests/run_tests.sh
```

Chaque test affiche `ok` ou `ÉCHEC` avec la raison, et le script sort en `1` si
au moins un test échoue. Les manifestes Kubernetes ont leur propre suite,
`validate_k8s.sh` (voir plus haut) : elle a besoin de `kubectl`, que l'image de
`test-scripts` ne fournit pas.

## Les autres vérifications en local

```bash
# Vérifier la syntaxe Bash
bash -n scripts/**/*.sh

# Lancer ShellCheck (même commande que la CI, stubs compris)
find scripts -type f \( -name '*.sh' -o -path 'scripts/tests/stubs/*' \) -print0 \
  | xargs -0 shellcheck --external-sources

# Vérifier que le Python compile
python3 -m py_compile scripts/ci/*.py

# Afficher l'aide de n'importe quel script
scripts/ci/build_and_push.sh --help
```
