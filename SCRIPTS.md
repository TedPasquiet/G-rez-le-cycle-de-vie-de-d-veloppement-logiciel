# Les scripts d'automatisation

Dans le dossier `scripts/` j'ai mis des petits scripts (en Bash et en Python) qui
automatisent des étapes répétitives du pipeline : construire les images, vérifier
la qualité, déployer, etc. L'idée c'est d'éviter d'écrire tout ça directement
dans le `.gitlab-ci.yml`, et de pouvoir aussi les lancer à la main pour tester.

## Quelques choix que j'ai faits

- **Gestion des erreurs** : en Bash je mets `set -euo pipefail` (le script s'arrête
  dès qu'il y a un problème), et en Python je gère les erreurs avec des `try/except`
  et des codes de sortie différents.
- **Sécurité** : les mots de passe et tokens viennent toujours de variables
  d'environnement, jamais écrits en dur dans le code, et je ne les affiche jamais
  dans les logs.
- **Pas de doublons** : tout ce qui est commun aux scripts Bash (les logs, les
  vérifications...) est regroupé dans `lib/common.sh`.
- **Aucune install** pour les scripts Python : j'utilise juste ce qui est fourni
  de base avec Python.
- Les scripts Bash sont vérifiés par **ShellCheck** dans la CI (job `shellcheck`).
- **Les scripts sont testés** à chaque commit (job `test-scripts`), sans toucher
  ni au registry ni au cluster — voir la section [Les tests](#les-tests) plus bas.

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

Les scénarios de performance eux-mêmes ne sont pas dans `scripts/` mais dans
`tests/k6/` (voir [QUALITY.md](QUALITY.md) §5), parce que ce sont des tests de
l'application, pas des outils du pipeline.

---

## `lib/common.sh`

Ce n'est pas un script qu'on lance : c'est un fichier de fonctions que les autres
scripts "sourcent" au début pour réutiliser les logs, les vérifications, etc.
Dedans il y a : `log_info/warn/error`, `die`, `require_cmd`, `require_env`, `retry`.

---

## `ci/build_and_push.sh`

Il construit une image Docker et l'envoie sur le registry (l'étape "livraison").
Il met deux tags sur l'image : le SHA du commit (fixe) et `latest`. Avec
`--scan`, il la passe à Trivy **avant** de la pousser.

⚠️ **L'ordre « scan, puis push » est une garantie.** Tant que le scan était une
ligne à part dans le job, placée après ce script, l'image était poussée puis
scannée : le job rougissait, mais le tag du SHA existait déjà au registry — et
`promote_image.sh` ne demande que l'existence de ce tag. Un tag de release posé
sur ce commit aurait promu une image que la porte venait de refuser. Constaté le
2026-10-02 : `back:5bf1d6a2` était au registry avec cinq CVE hautes, job rouge.
Désormais une image refusée, ou qu'on n'a pas pu scanner, n'atteint pas le
registry.

Le scan lui-même est délégué à [`trivy_scan.sh`](#citrivy_scansh), qui en garde
un relevé.

Options principales : `--context`, `--image`, `--tag` (obligatoires),
`--moving-tag` (défaut `latest`), `--dockerfile`, `--scan`, et pour le scan :
`--scan-severity` (défaut `HIGH,CRITICAL`), `--scan-report` (défaut
`reports/trivy-image.json`), `--trivy-image` (lance Trivy par `docker run`).
Il a besoin des variables `REGISTRY_HOST`, `REGISTRY_USER`, `REGISTRY_PASSWORD`.
Il renvoie : `0` si ok, `1` si problème de config ou d'exécution (scan
impossible compris), `2` si l'image est trop vulnérable — push annulé.

```bash
REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
scripts/ci/build_and_push.sh -c ./back -i "$CI_REGISTRY_IMAGE/back" -t "$CI_COMMIT_SHORT_SHA" \
  --scan --scan-report reports/trivy-image-back.json --trivy-image "$TRIVY_IMAGE"
```

Utilisé par les jobs `package-back` et `package-front`.

---

## `ci/trivy_scan.sh`

Il lance un scan Trivy **bloquant** et en garde une trace : un rapport JSON, et
le tableau lisible à côté (même nom, extension `.txt`). Avant lui, Trivy
n'écrivait que dans le journal du job : un constat se lisait le jour où le job
rougissait, puis disparaissait avec le journal.

**Deux passages, et c'est délibéré.** Le premier est le _relevé_ (`--format
json`, sans porte) ; le second est la _porte_ (tableau, code de sortie
bloquant). Un seul passage suivi de `trivy convert` aurait suffi sur un poste,
mais dans les jobs `package-*` Trivy tourne dans un conteneur lancé par
`docker run` contre un démon dind : le JSON en sort par la sortie standard, qui
marche partout, là où un fichier demanderait un montage dépendant du runner. Le
second passage réutilise la base et l'analyse en cache.

**Ce que le relevé ne peut pas faire : masquer la porte.** Le code de sortie est
celui du second passage. Si le relevé échoue, c'est une erreur technique (`1`)
et **aucun rapport n'est écrit** — un fichier vide ne doit pas passer pour
« zéro faille ». Et quand la porte se ferme, les deux fichiers existent quand
même : c'est ce jour-là qu'on veut les lire.

⚠️ Le rapport est filtré **comme la porte** (mêmes sévérités, même fichier
d'exclusions) : il décrit ce que la porte a vu, pas tout ce que Trivy sait. Un
constat `MEDIUM` n'y figure pas.

Options : `--mode` (`fs` ou `image`), `--target`, `--report` (tous
obligatoires ; le rapport doit finir par `.json`), `--severity` (défaut
`HIGH,CRITICAL`), `--scanners`, `--ignorefile`, `--docker-image` (lance Trivy
par `docker run` ; réservé au mode `image`, sans `--ignorefile`, puisque rien du
dépôt n'est monté dans ce conteneur).
Il renvoie : `0` aucun constat bloquant, `1` problème de configuration ou scan
impossible, `2` au moins un constat — la porte est fermée.

```bash
scripts/ci/trivy_scan.sh -m fs -T . -r reports/trivy-fs.json \
  --scanners vuln,secret,misconfig --ignorefile .trivyignore.yaml
scripts/ci/trivy_scan.sh -m image -T "$IMAGE:$CI_COMMIT_SHORT_SHA" \
  -r reports/trivy-image-back.json --docker-image "$TRIVY_IMAGE"
```

Utilisé par le job `trivy-fs` directement, et par `package-back` /
`package-front` à travers `build_and_push.sh --scan`. Les trois rapports sont
publiés en artefacts, y compris quand le job échoue :

| Job             | Rapport JSON                     | Tableau                         |
| --------------- | -------------------------------- | ------------------------------- |
| `trivy-fs`      | `reports/trivy-fs.json`          | `reports/trivy-fs.txt`          |
| `package-back`  | `reports/trivy-image-back.json`  | `reports/trivy-image-back.txt`  |
| `package-front` | `reports/trivy-image-front.json` | `reports/trivy-image-front.txt` |

Ces noms sont une interface : `collect_security.py` les lit.

**Ce qui n'est pas fait** : le rapport au format GitLab (`reports:
container_scanning`, gabarit `@contrib/gitlab.tpl`). Il demanderait un troisième
passage, pour un affichage que GitLab réserve à l'offre Ultimate.

---

## `ci/promote_image.sh`

Il pose un numéro de version SemVer sur une image **déjà construite et déjà
poussée** : il la tire du registry, lui ajoute le tag de version, la repousse.
Il ne construit rien.

C'est ce qui fait qu'une version est traçable. Deux builds du même commit ne
produisent pas les mêmes couches, donc reconstruire au moment du tag donnerait
une image qui n'est plus celle que les scans et k6 ont éprouvée. En retaguant,
`back:1.4.0` et `back:a1b2c3d` sont le même digest.

Il refuse ce qui n'est pas du SemVer (`v1.4`, `latest`, `v01.4.0` — zéro de
tête), et refuse aussi les métadonnées de build `+…`, qu'un tag Docker
n'accepte pas. Si l'image source est absente du registry, il échoue en le
disant : on ne publie pas un numéro de version qui ne désigne aucun artefact.

Options : `--image`, `--from-tag`, `--version` (toutes obligatoires).
Il a besoin des variables `REGISTRY_HOST`, `REGISTRY_USER`, `REGISTRY_PASSWORD`.

```bash
REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
scripts/ci/promote_image.sh -i "$CI_REGISTRY_IMAGE/back" \
  -f "$CI_COMMIT_SHORT_SHA" -v "$CI_COMMIT_TAG"
```

Utilisé par les jobs `promote-back` et `promote-front`, qui ne tournent que sur
un pipeline de tag. Voir [RELEASE.md](RELEASE.md) §2.1.

---

## `ci/check_version.sh`

Il vérifie que le numéro de version déclaré dans le dépôt correspond au tag de
release qu'on pose. Trois fichiers sont contrôlés : `front/package.json`
(version du front), `back/build.gradle` (version du jar) et l'`appVersion` de
`helm/microcrm/Chart.yaml` (version de l'application déployée).

Deux versions sont **hors périmètre, et c'est délibéré** : le `package.json` de
la racine décrit l'outillage du dépôt (hooks, commitlint, Prettier) et porte
d'ailleurs un autre nom, `microcrm-tooling` ; et le champ `version` du chart est
la version du CHART, que la convention Helm distingue de celle de
l'application — le chart peut changer sans que l'application bouge.

Il rapporte **toutes** les divergences, pas seulement la première, et un champ
renommé le fait échouer au lieu de passer sur une chaîne vide.

Option : `--version` (obligatoire). Codes : `0` concordance, `1` erreur de
configuration, `2` au moins une divergence.

```bash
scripts/ci/check_version.sh --version "$CI_COMMIT_TAG"
```

Utilisé par le job `version-consistency`, qui ne tourne que sur un pipeline de
tag et dans la première étape : inutile de construire et de scanner pour
découvrir la divergence au moment de déployer.

---

## `ci/release_notes.sh`

Il écrit la description de la Release GitLab d'une version : le commit, le
pipeline, et pour chaque image **ses deux tags** — le numéro de version et le
SHA. C'est leur égalité qui rend une version traçable, puisque la promotion est
un retag et non une reconstruction.

Il ne crée pas la Release : c'est le mot-clé `release:` du job qui le fait, une
fois ce fichier écrit, en appelant `glab release create` avec le jeton du job.
Il n'interroge ni le registry ni l'API — il met en forme ce que GitLab pose déjà
dans l'environnement.

Une variable absente l'arrête, sans fichier écrit : une Release qui annoncerait
l'image « : » serait pire que pas de Release.

Écrit en **sh POSIX**, comme `validate_k8s.sh` et pour la même raison : l'image
du job (`$GLAB_IMAGE`, basée sur Alpine) n'a que busybox `sh`.

Paramètre : le fichier de sortie (obligatoire). Variables lues :
`CI_COMMIT_TAG`, `CI_COMMIT_SHA`, `CI_REGISTRY_IMAGE` (obligatoires),
`CI_COMMIT_SHORT_SHA`, `APP_BACK_NAME`, `APP_FRONT_NAME`, `CI_PIPELINE_URL`,
`CI_PROJECT_URL`. Il renvoie : `0` fichier écrit, `1` paramètre ou variable
manquante.

```bash
CI_COMMIT_TAG=v1.4.0 CI_COMMIT_SHA=$(git rev-parse HEAD) \
CI_REGISTRY_IMAGE=registry.gitlab.com/xxx \
scripts/ci/release_notes.sh reports/release-notes.md
```

Utilisé par le job `release`, qui ne tourne que sur un pipeline de tag et
seulement après `promote-back` **et** `promote-front`. Voir
[RELEASE.md](RELEASE.md) §2.2.

---

## `ci/terraform_check.sh`

Contrôle les configurations Terraform de `terraform/environments/`. Trois modes,
qui n'ont ni le même coût ni la même valeur de preuve :

| Mode                  | Ce qu'il fait                                                            | Où il tourne                                            |
| --------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------- |
| `--validate` (défaut) | `fmt -check`, puis `init -backend=false` et `validate` par environnement | job `terraform-validate`, sur toutes les branches       |
| `--plan`              | `init`, `plan -lock=false -out=plan.cache`, puis le résumé `plan.json`   | job `terraform-plan` : MR, `develop`, `main` — bloquant |
| `--apply`             | `init` puis `apply plan.cache` (à défaut : `apply -auto-approve`)        | jobs `terraform-apply-<env>`, manuels sur `main`        |

⚠️ **`--plan` et `--apply` exigent `$TF_STATE_BASE_URL`** (et les identifiants
`TF_HTTP_USERNAME` / `TF_HTTP_PASSWORD`) : ils lisent l'état partagé. Le script
compose `TF_HTTP_ADDRESS` **par environnement**, dans la boucle — un état
distinct et verrouillé pour chacun, voir [TERRAFORM.md](TERRAFORM.md) §4. Sans
cette adresse, il refuse de commencer en nommant la variable, plutôt que de
laisser `init` échouer sur un message de backend.

`--validate`, lui, n'exige RIEN : `-backend=false`, aucun état, aucun cluster.
C'est ce qui le rend jouable sur n'importe quel runner et sur toutes les
branches — un test de `run_tests.sh` interdit de le lui faire perdre.

Les environnements sont **découverts**, jamais listés en dur : un troisième
environnement ajouté demain est contrôlé sans toucher au script. Tous sont
traités même après un échec, pour que deux erreurs se lisent en une exécution.

⚠️ **`--apply` exige `-e <environnement>`.** Appliquer en boucle sur tous les
environnements ferait passer la production dans le même geste que le staging,
sans que rien ne le distingue à la lecture du pipeline. La confirmation
interactive qu'on perd avec `-auto-approve` est remplacée par l'obligation
d'écrire l'environnement visé.

⚠️ **Ce que `--plan` prouve, depuis qu'il lit l'état partagé.** Il compare le
dépôt à ce qui existe réellement : une modification faite à la main dans le
cluster apparaît en dérive, et un « 0 to add, 0 to change » est une information.
Ça n'a pas toujours été le cas, et l'ancienne limite valait d'être mesurée : avec
un état local jamais commité, la CI repartait d'un état vide et annonçait « tout
à créer » quoi qu'il arrive ; avec un kubeconfig valide pointant sur un cluster
éteint, `plan` sortait même en `0` — il n'y avait rien à rafraîchir.

Ce qu'il ne prouve toujours pas : que l'`apply` passera. Un `Deployment` ne
consomme aucun quota, seuls ses pods en consomment. Le script le redit à
l'exécution, parce qu'une sortie de job se lit sans le code sous les yeux.

⚠️ **`--require-plan` : appliquer le plan relu, ou rien.** `--plan` enregistre
son plan dans `<env>/plan.cache` (publié en artefact par la CI) et `--apply`
applique **ce fichier** plutôt que d'en recalculer un autre — sans quoi ce qui
part en production n'est pas formellement ce qui a été approuvé en merge
request. Avec `--require-plan`, que passent les jobs de CI, l'absence de plan
enregistré est un **échec** : un artefact expiré ou un job relancé seul ne doit
pas dégrader la garantie en silence. Sans le drapeau, c'est le mode d'un poste —
Terraform replanifie, avec un avertissement. Et si l'état a bougé entre les
deux, c'est Terraform qui refuse : « Saved plan is stale ».

Le second fichier, `<env>/plan.json`, ne contient que trois entiers
(create/update/delete), et leur somme est écrite à la racine du répertoire des
environnements, dans `plan-global.json` : c'est **elle** qui alimente le widget
Terraform des merge requests, parce que GitLab n'accepte qu'un seul fichier de
rapport par job (« only one file can be sent as raw » — mesuré, le job échoue
sinon, alors même que le plan a réussi). Les deux demandent `jq`, qui reste
**facultatif** : absent, le script prévient et continue — un widget muet ne
justifie pas de faire échouer un plan qui a réussi. Le JSON complet du plan, lui,
n'est jamais écrit sur le disque.

```bash
scripts/ci/terraform_check.sh                       # validate, hors cluster
scripts/ci/terraform_check.sh --plan
scripts/ci/terraform_check.sh --apply -e production
```

Le détail des ressources est dans [TERRAFORM.md](TERRAFORM.md).

## `ci/ansible_check.sh`

Contrôle le projet Ansible : `--syntax-check` du playbook, puis `ansible-lint`.
Utilisé par le job `ansible-lint`.

**Sa raison d'être tient dans un `cd`.** `ansible/ansible.cfg` n'est lu que si le
répertoire courant est `ansible/` : un `ansible-lint ansible/` lancé depuis la
racine du dépôt l'ignore en silence, tourne sans inventaire et sans la
configuration du projet — et sort en `0`. Le script entre donc dans le
répertoire avant d'agir, et c'est ce que les stubs vérifient en journalisant
leur répertoire courant.

Comme pour Terraform, les échecs sont cumulés : une erreur de syntaxe n'escamote
pas le lint.

```bash
scripts/ci/ansible_check.sh
scripts/ci/ansible_check.sh --collections   # installe d'abord les collections figées
```

Le périmètre des rôles est dans [ANSIBLE.md](ANSIBLE.md).

## `ci/notify.py`

Il annonce le résultat d'une étape du pipeline sur un canal d'équipe — tout ce
qui accepte un webhook JSON (Slack, Mattermost, Discord). Le manque qu'il
comble : un déploiement raté ne se voyait qu'en ouvrant GitLab.

**Ce qui est notifié.** Les déploiements le sont dans les deux cas, succès comme
échec, par l'`after_script` de `.deploy_template`. Le reste du pipeline n'est
notifié qu'en cas d'échec, par le job `notify-echec`. Un canal qui annonce
chaque pipeline vert devient un canal qu'on n'ouvre plus.

**Deux partis pris qui protègent le pipeline**, et c'est l'essentiel de ce
script :

- **Webhook absent = rien à faire, et surtout pas un échec.** Le script sort en
  0 et écrit le message dans le journal du job. Sans cela, un dépôt cloné sans
  la variable verrait tous ses pipelines rougir sur une notification non
  configurée — et on apprendrait à ignorer les jobs rouges.
- **Un envoi qui échoue ne fait jamais échouer le pipeline.** Un canal
  indisponible ne dit rien sur la qualité du déploiement. Faire rougir un
  déploiement réussi parce que Slack est en panne serait une fausse alerte.

Options : `--statut` et `--sujet` (obligatoires), `--detail`, `--dry-run`.
Variable d'environnement : `NOTIFY_WEBHOOK_URL`, jamais dans le dépôt.

```bash
scripts/ci/notify.py --statut "$CI_JOB_STATUS" --sujet "Déploiement production"
```

Utilisé par l'`after_script` de `.deploy_template` et par le job
`notify-echec` (`.gitlab/ci/notify.yml`).

---

## `ci/collect_dora.py`

Il calcule les quatre indicateurs DORA du projet à partir de l'historique des
pipelines GitLab, et les sort en JSON : fréquence de déploiement, délai de mise
en production, temps de rétablissement, taux d'échec des changements.

**La règle qui gouverne tout le script : un indicateur qu'on ne peut pas mesurer
vaut `null`, accompagné de sa raison — jamais `0`.** Un `0` se lit comme une
performance ; un délai de livraison de zéro heure, sur un projet qui n'a jamais
livré, serait le pire mensonge qu'un tableau de bord puisse afficher.

**Comment il fonctionne.** Il lit la liste des pipelines, puis les jobs de
chacun, et repère les déploiements et les retours arrière par leur **nom de
job** — l'API `/deployments` de GitLab, elle, exige un jeton même sur un projet
public. Puis :

| Indicateur   | Calcul                                                                       |
| ------------ | ---------------------------------------------------------------------------- |
| Fréquence    | déploiements réussis ÷ durée de la fenêtre                                   |
| Délai        | médiane de (fin du déploiement réussi − date du commit de tête)              |
| MTTR         | médiane de (fin du déploiement réussi − fin du premier échec de la série)    |
| Taux d'échec | tentatives ratées ÷ tentatives ; une réussite suivie d'un rollback est ratée |

Une tentative est un job de déploiement **réellement exécuté** (`success` ou
`failed`) : un job `manual` jamais déclenché n'est pas un déploiement, et un job
`canceled` n'est pas compté — on ne sait pas si la production a été touchée.
Les événements retenus sont recopiés dans le JSON, pour que chaque chiffre se
vérifie à la main.

Comme les autres scripts Python du dépôt, il n'utilise que la bibliothèque
standard.

Options : `--project` (id ou chemin, défaut `84606666`), `--host` (défaut
`https://gitlab.com`), `--token` (sinon `$GITLAB_TOKEN`), `--days` (fenêtre
glissante, défaut 30 ; `0` = tout l'historique), `--deploy-jobs` (défaut
`deploy-staging,deploy-production`), `--rollback-jobs` (défaut
`rollback-production`), `--output` (sinon la sortie standard),
`--elasticsearch` et `--es-index` (envoi en `_bulk`, défaut `microcrm-dora`),
`--fixtures` (rejoue des réponses d'API enregistrées au lieu du réseau).

**Conditions d'exécution.** Un accès réseau à l'API GitLab, et rien d'autre : le
jeton est **facultatif** tant que le projet est public. Fourni, il part dans
l'en-tête `PRIVATE-TOKEN` et n'est ni affiché ni recopié dans le JSON. Le mode
`--fixtures` n'a besoin ni de jeton ni de réseau — c'est lui que jouent les
tests.

Il renvoie : `0` collecte terminée — **même si des indicateurs sont `null`**,
c'est un résultat — et `1` sur une erreur technique (réseau, API en erreur,
fixtures illisibles, écriture impossible, envoi Elasticsearch refusé).

```bash
scripts/ci/collect_dora.py --days 30 --output reports/dora.json
scripts/ci/collect_dora.py --fixtures scripts/tests/fixtures --days 0
scripts/ci/collect_dora.py --days 0 --elasticsearch http://127.0.0.1:9200
```

Utilisé par le job `dora-metrics` (`.gitlab/ci/deploy.yml`), sur `develop`,
`main` et les tags, qui publie `reports/dora.json` en artefact pendant 30 jours.
Trois choses à savoir sur ce job :

- **Il ne fait jamais rougir le pipeline** (`allow_failure: true`) : une mesure
  qui n'a pas pu être prise — API lente, quota de requêtes anonymes — ne dit
  rien de ce qui est livré. Dans ce cas aucun artefact n'est publié : un fichier
  absent, pas un fichier faux.
- **Il lit l'historique tel qu'il est au démarrage du pipeline** (`needs: []`).
  Le déploiement que ce pipeline permettra n'y figure pas ; il apparaît à la
  collecte suivante. L'attendre n'est pas possible : les jobs `deploy-*` sont
  manuels et bloquants.
- **Il n'alimente pas Elasticsearch.** L'Elasticsearch du projet vit dans le
  cluster, sans adresse joignable depuis un conteneur de job. Le drapeau
  `--elasticsearch` n'est donc pas passé en CI ; le tableau de bord reste
  alimenté depuis un poste (voir [MONITORING.md](MONITORING.md)).

Exécuté contre l'API réelle le 2026-10-02 (fenêtre de 30 jours) : 57 pipelines
lus en 70 s, 9 tentatives de déploiement dont 5 réussies.

---

## `ci/collect_security.py`

Il transforme les rapports des scanners de sécurité en documents Elasticsearch,
pour le tableau de bord Kibana « sécurité » : un document `constat` par
vulnérabilité, misconfiguration ou secret, un document `scan` par rapport lu, un
document `exception` par entrée de `.trivyignore.yaml`.

Même règle que `collect_dora.py` : **l'absence de donnée n'est pas un zéro.** Un
rapport lu sans constat produit un `scan` à `total: 0` — c'est une mesure. Un
rapport non fourni ne produit rien. Un rapport illisible fait échouer le script.

⚠️ **Il ne juge pas.** Il ne sort jamais en erreur parce qu'il y a des
vulnérabilités : la porte reste `trivy_scan.sh`, dans les jobs `trivy-fs` et
`package-*`.

Il lit les rapports que ces jobs publient (`reports/trivy-fs.json`,
`reports/trivy-image-back.json`, `reports/trivy-image-front.json`) et le rapport
JSON de Dependency-Check (`back/build/reports/dependency-check-report.json`,
produit depuis que `formats` contient `'JSON'` dans `back/build.gradle`).

Options : `--trivy-report` et `--dependency-check-report` (répétables),
`--optional` (un rapport introuvable est signalé puis ignoré), `--trivyignore` /
`--no-trivyignore`, `--commit`, `--ref`, `--date`, `--output`,
`--elasticsearch`, `--es-index` (défaut `microcrm-security`).
Il renvoie : `0` collecte terminée, même sans aucun constat ; `1` erreur
technique — aucune source, rapport introuvable sans `--optional`, rapport
présent mais invalide, fichier d'exceptions illisible, `--date` illisible, envoi
Elasticsearch raté.

⚠️ **Ce qu'il collecte dépend de ce que les rapports contiennent.** Les rapports
publiés par la CI sont filtrés comme la porte : HIGH et CRITICAL seulement,
exclusions de `.trivyignore.yaml` appliquées. Collectés tels quels, ils donnent
donc `0` constat MEDIUM ou LOW (non demandés, pas absents) et `0` constat
excepté (Trivy les a retirés avant d'écrire). Le document `scan` ne distingue
pas ces deux régimes ; l'historique du tableau de bord du 2026-10-02 a été
produit par des scans sans filtre, rejoués sur poste.

```bash
scripts/ci/collect_security.py \
  --trivy-report reports/trivy-fs.json \
  --trivy-report reports/trivy-image-back.json \
  --dependency-check-report back/build/reports/dependency-check-report.json \
  --optional --elasticsearch http://127.0.0.1:9200
```

**Aucun job ne l'exécute** : comme pour `collect_dora.py`, l'Elasticsearch du
cluster n'est pas joignable depuis un job. Il se lance depuis un poste, sur les
artefacts téléchargés. **Ce qui n'a pas été vérifié** : la lecture d'un rapport
Dependency-Check réel (seulement une fixture fabriquée) et celle des rapports
réellement publiés par un pipeline, ces jobs n'ayant pas encore tourné.

Tests : un bloc `ci/collect_security.py` de `run_tests.sh`, sur les fixtures
fabriquées de `scripts/tests/fixtures/security/` (décrites dans leur
`README.md`).

---

## `monitoring/install_alerting.py`

Il installe l'alerting de la stack de supervision : le modèle de l'index
`microcrm-alerts` dans Elasticsearch, puis les règles d'alerte Kibana décrites
par les fichiers de `k8s/elk/alerting/rules/`.

**Le manque qu'il comble.** Une règle créée à la souris vit dans l'index
`.kibana` d'un pod et disparaît avec lui — et une alerte qui a disparu ne
prévient pas qu'elle a disparu. Ici la règle est un fichier, et ce script est
la seule façon prévue de la faire exister dans une instance.

**Comment ça marche.** Un fichier JSON par règle ; le nom du fichier est
l'identifiant de la règle dans Kibana, et son contenu le corps attendu par
`POST /api/alerting/rule/<id>`. Cet identifiant choisi rend le script
idempotent : règle absente, création (`POST`) ; règle présente, mise à jour sur
place (`PUT`). Vérifié le 2026-10-02 : première exécution « 8 règles créées »,
seconde « 8 règles mises à jour », toujours huit au total.

Quatre modes, exclusifs :

| Mode        | Ce qu'il fait                                                                                      | À qui il parle          |
| ----------- | -------------------------------------------------------------------------------------------------- | ----------------------- |
| sans option | Installe le modèle d'index, puis crée ou met à jour chaque règle                                   | Kibana et Elasticsearch |
| `--secret`  | Crée le Secret `kibana-encryption-key` (valeur aléatoire) s'il n'existe pas, puis redémarre Kibana | `kubectl`               |
| `--dry-run` | Relit et contrôle les fichiers de règles, sans aucun appel réseau — le mode des tests              | personne                |
| `--etat`    | Affiche l'état de chaque règle : activée, dernière exécution, alerte active. Ne modifie rien       | Kibana                  |

`--regles <dossier>` change le dossier des fichiers de règles. Variables lues :
`KIBANA_URL` (défaut `http://127.0.0.1:5601`), `ELASTICSEARCH_URL` (défaut
`http://127.0.0.1:9200`), `LOGGING_NAMESPACE` (défaut `logging`, mode
`--secret`).

**Conditions d'exécution.** Python 3, bibliothèque standard seule. Hors
`--dry-run`, deux `port-forward` ouverts vers Kibana et Elasticsearch ; pour
`--secret`, un `kubectl` qui vise le cluster. Le script **refuse d'installer**
tant que Kibana n'a pas de clé de chiffrement permanente, et dit quoi lancer.

**Pourquoi `--secret` est un mode à part.** Redémarrer Kibana coupe le
`port-forward` par lequel on lui parle : un script qui ferait les deux d'un
trait échouerait toujours à la seconde moitié. Et la clé n'est écrite nulle
part ailleurs que dans le Secret : elle est envoyée à `kubectl` par l'entrée
standard, jamais en argument, un argument se lisant dans `ps`.

Il renvoie : `0` tout est en place (en `--dry-run`, tous les fichiers sont
valides) ; `1` fichier de règle invalide, Kibana ou Elasticsearch injoignable,
clé de chiffrement manquante, ou appel refusé ; `2` erreur d'utilisation.

```bash
scripts/monitoring/install_alerting.py --secret     # une fois par cluster
kubectl apply -k k8s/elk -n logging                 # les connecteurs préconfigurés
scripts/monitoring/install_alerting.py              # crée ou met à jour les règles
scripts/monitoring/install_alerting.py --etat
```

Tests : un bloc `monitoring/install_alerting.py` de `run_tests.sh`
(33 assertions), contre de faux `kubectl` et des fichiers de règles abîmés.
**Non vérifié** : la création réelle du Secret par `--secret` — celui du
cluster a été créé à la main avant que le script n'existe ; seuls la branche
« le Secret existe déjà » et le chemin complet contre le faux `kubectl` ont été
éprouvés. **Aucun job ne l'exécute.** Le détail des règles est dans
`k8s/elk/alerting/README.md` et [MONITORING.md](MONITORING.md) §11.

---

## `docs/build_pdf.sh`

Il produit les PDF des livrables à partir de leur source Markdown, en passant
par un HTML accessible. Cette chaîne se jouait à la main (`npx marked` puis
Chrome) : rien ne garantissait que deux PDF sortent avec la même mise en page,
ni qu'ils soient lisibles par un lecteur d'écran.

**Pourquoi un PDF « balisé ».** Un PDF ordinaire est une suite de glyphes : un
lecteur d'écran y lit du texte sans savoir ce qui est un titre, un tableau ou
une image. Un PDF balisé embarque l'arbre de structure du document et sa
langue. Chrome le produit à partir de la structure du HTML : c'est donc le HTML
que soigne le script.

**Comment ça marche**, pour chaque document : chaque bloc Mermaid est remplacé
par une image dont le texte alternatif vient de `accTitle` / `accDescr`, ou à
défaut du titre de la section ; les schémas sont rendus par `mermaid-cli` ; le
Markdown est converti par `marked` et enveloppé dans une page qui déclare
`lang="fr"`, un titre et une feuille d'impression ; Chrome headless imprime le
PDF, signets compris ; enfin le script **vérifie** le fichier produit — arbre de
structure, marquage, langue, signets — et échoue s'il en manque un.

Options : `-o, --output-dir` (défaut : à côté de chaque source), `-w,
--work-dir` (fichiers intermédiaires ; défaut : répertoire temporaire supprimé),
`--format svg|png` (défaut `svg`), `--html-only` (s'arrête au HTML, demande
`-w`). Sans argument, il traite les cinq livrables de `docs/`. Variables :
`CHROME_BIN`, `MARKED_VERSION` (16.4.2), `MERMAID_CLI_VERSION` (11.17.0) — les
versions sont figées, pour qu'un rendu ne change pas tout seul d'un jour à
l'autre.

**Conditions d'exécution.** `npx` (donc Node), et Chrome ou Chromium. Pas
d'exécution en CI.

Il renvoie : `0` ok ; `1` problème de configuration ou d'exécution ; `4` un PDF
produit n'est pas balisé.

```bash
scripts/docs/build_pdf.sh                                  # les cinq livrables
scripts/docs/build_pdf.sh -o /tmp/pdf docs/plan-optimisation-release.md
```

**Vérifié le 2026-10-02** vers un répertoire de travail, sur quatre documents ;
balisage, langue `fr`, signets et textes alternatifs constatés dans le PDF du
plan d'optimisation (`pdfinfo` : `Tagged: yes`). **Les PDF de `docs/`
n'ont pas encore été régénérés** par ce script. Il n'est couvert par aucun test
de `run_tests.sh`.

---

## `tests/check_accessibilite_docs.py`

Il contrôle mécaniquement l'accessibilité des documents livrables en Markdown —
la part du RGAA 4.1 et des WCAG 2.1 qui se vérifie à la machine, et elle seule.
La justesse d'un texte alternatif ou la clarté d'une phrase demandent une
relecture humaine, qu'aucun code de sortie ne remplace.

Ce qu'il contrôle : un seul titre de niveau 1 et aucun saut de niveau ; un texte
alternatif non vide, qui ne soit pas un nom de fichier, sur chaque image ; une
ligne d'en-tête sans cellule vide sur chaque tableau ; aucun lien libellé « ici »
ou « cliquez ici » ; un texte à proximité de chaque schéma Mermaid ; aucun
pictogramme qui porte seul une information. Il **signale** sans en faire un
défaut les phrases de plus de 60 mots (`--strict` les compte comme défauts,
`--max-mots N` règle le seuil).

Sans fichier en argument, il contrôle les cinq livrables de `docs/` et
`RELEASE.md`. Options : `--strict`, `--max-mots N`, `--quiet`.

Il renvoie : `0` aucun défaut ; `1` au moins un défaut ; `2` erreur d'usage ou
fichier introuvable.

```bash
python3 scripts/tests/check_accessibilite_docs.py            # les six livrables
python3 scripts/tests/check_accessibilite_docs.py MONITORING.md
```

Python standard seul. **Il n'est branché sur aucun job** — il pourrait l'être à
l'étape `lint`, sans dépendance — et il ne vérifie ni la langue du document (le
rôle de `build_pdf.sh`), ni le contraste des schémas rendus, ni le
développement des sigles.

---

## `ci/quality_gate.py`

Il demande à SonarCloud si le Quality Gate est passé, et fait échouer le job si
ce n'est pas le cas. Comme l'analyse Sonar prend un peu de temps, il réessaie
jusqu'à avoir la réponse.

Options : `--project-key` (obligatoire), `--host` (défaut `https://sonarcloud.io`),
`--branch`, `--timeout` (300), `--poll` (10). Il a besoin de `SONAR_TOKEN`.
Il renvoie : `0` si c'est bon, `1` si problème technique, `2` si le gate échoue.

```bash
SONAR_TOKEN=$SONAR_TOKEN scripts/ci/quality_gate.py \
  --project-key pasquietted_mon-projet --branch "$CI_COMMIT_REF_NAME"
```

Utilisé par le job `quality-gate`.

---

## `ci/check_coverage.py`

Il lit le rapport de couverture de JaCoCo et échoue si la couverture est en
dessous d'un pourcentage donné. C'est un petit contrôle rapide en plus de Sonar.

Options : `--report` (obligatoire), `--min` (défaut 80), `--counter` (défaut LINE).
Il renvoie : `0` si ok, `1` si erreur, `2` si couverture trop basse.

```bash
scripts/ci/check_coverage.py \
  --report back/build/reports/jacoco/test/jacocoTestReport.xml --min 70
```

Utilisé par le job `coverage-gate`.

---

## `deploy/deploy.sh`

Il déploie une image sur Kubernetes. Si le déploiement échoue ou prend trop de
temps, il revient tout seul à la version d'avant (voir [RELEASE.md](RELEASE.md)).

Options : `--namespace`, `--deployment`, `--container`, `--image` (obligatoires),
`--timeout` (défaut 180s), `--no-auto-rollback`. Il a besoin de `KUBECONFIG`.
Il renvoie : `0` si ok, `1` si problème de config, `3` si le déploiement rate.

```bash
KUBECONFIG=$PWD/kube.cfg scripts/deploy/deploy.sh \
  -n staging -d back -c back -i "$CI_REGISTRY_IMAGE/back:$CI_COMMIT_SHORT_SHA"
```

Utilisé par les jobs `deploy-staging` et `deploy-production`.

---

## `deploy/rollback.sh`

À utiliser quand une version pose problème en prod : il remet la version d'avant
(ou une version précise avec `--to-revision`).

Options : `--namespace`, `--deployment` (obligatoires), `--to-revision`
(défaut : version d'avant), `--timeout` (défaut 180s). Il a besoin de `KUBECONFIG`.
Il renvoie : `0` si ok, `1` si problème de config, `3` si le rollback rate.

```bash
KUBECONFIG=$PWD/kube.cfg scripts/deploy/rollback.sh -n production -d back
```

Utilisé par le job `rollback-production`.

---

## `tests/run_k6.sh`

Il lance un scénario de test de performance k6 (dossier `tests/k6/`). C'est un
raccourci de confort : il choisit le bon fichier, écrit le rapport JSON au bon
endroit, et surtout **traduit le code de sortie de k6** en quelque chose
d'exploitable — k6 sort en 99 quand un seuil est dépassé et en 107 quand le
script plante, ce qui n'est pas très parlant dans un log de CI.

Toute la logique du test (charge, seuils, parcours) est dans les fichiers
`tests/k6/*.js`, pas dans le script : c'est ce qui garantit que la commande
locale et le job CI mesurent la même chose.

Options : `--scenario` (`smoke` par défaut, ou `load`, ou `stress`), `--url`,
`--output-dir` (défaut `reports/k6`), `--no-report`, et tout ce qui suit `--`
est passé tel quel à k6.

Codes de sortie : `0` tout va bien · `1` problème de configuration ·
`2` seuils de performance non tenus · `3` le test n'a pas pu aller au bout
(API injoignable, k6 en erreur).

```bash
scripts/tests/run_k6.sh                             # smoke sur localhost:8080
scripts/tests/run_k6.sh --scenario load --url http://back:8080
K6_LOAD_VUS=25 scripts/tests/run_k6.sh -s load      # surcharger la charge
scripts/tests/run_k6.sh -s smoke -- --vus 3         # option passée à k6
```

Le détail des scénarios et des seuils est dans [QUALITY.md](QUALITY.md) §5.

---

## `tests/validate_k8s.sh`

Il valide les manifestes Kubernetes du dossier `k8s/` **sans cluster** : il
construit chaque overlay avec le Kustomize embarqué dans `kubectl`, puis vérifie
le rendu. C'est le pendant de `run_tests.sh` pour l'infrastructure — au lieu de
tester les scripts, il teste ce que Kustomize produit réellement. Quand `helm`
est disponible, il en fait autant du chart `helm/microcrm/` et compare les deux
rendus.

Ce qu'il vérifie :

- chaque overlay (`staging`, `production`) se construit ;
- les Deployments s'appellent `$APP_BACK_NAME` / `$APP_FRONT_NAME` **et portent
  un conteneur du même nom** — c'est le contrat de `deploy.sh`, qui exécute
  `kubectl set image deployment/back back=…`. Un `namePrefix:` casse le premier,
  un renommage de conteneur casse le second, et aucun des deux ne fait échouer
  `kubectl apply` ;
- toute ConfigMap référencée par un Deployment existe dans le rendu (une
  référence morte n'échoue pas à l'`apply` : elle bloque le pod au démarrage) ;
- les sondes visent un port réellement déclaré par leur conteneur ;
- chaque conteneur porte `runAsNonRoot: true` et
  `allowPrivilegeEscalation: false` — contrôlés **au niveau conteneur**, parce
  qu'une valeur posée là écrase celle du pod ;
- aucune image en `latest` ni sans tag ;
- chaque Deployment référence le Secret de tirage d'images attendu
  (`$REGISTRY_SECRET_NAME`) : le registry est privé, et un nom qui diverge de
  celui que crée la CI laisse tous les pods en `ImagePullBackOff` sans que
  `kubectl apply` ne signale quoi que ce soit ;
- aucun hôte d'Ingress en `.invalid` ne subsiste dans le rendu d'un overlay : la
  base n'en porte que de non résolvables, donc un `.invalid` qui survit signale
  un patch d'Ingress oublié (voir K8S.md §7) ;
- staging et production produisent des valeurs différentes (ConfigMap, hôte
  d'Ingress, ressources du back) : c'est la preuve que les patches d'overlay
  mordent au lieu d'être silencieux ;
- **le chart Helm passe exactement les mêmes contrôles** (`helm template … -f
values-<env>.yaml`, étiquetés `helm/staging` et `helm/production`) ;
- **et surtout : son rendu est identique à celui de l'overlay correspondant**,
  au seul label `app.kubernetes.io/managed-by` près (`kustomize` d'un côté,
  `helm` de l'autre). Deux descriptions de la même application, c'est deux
  occasions de diverger ; c'est cette assertion-là qui rend la divergence
  visible ici plutôt qu'au déploiement. En cas d'écart, le script affiche les
  premières lignes divergentes, côté par côté, sous la forme de faits
  (`Kustomize seul : Deployment/back …limits.memory = 1Gi`) : on voit quel champ
  a bougé sans relancer d'outil.

**Quand `helm` est absent** — c'est le cas du job `lint-k8s`, dont l'image
`$KUBECTL_IMAGE` ne le fournit pas — la section Helm n'est ni réussie ni en
échec : elle est marquée `ignoré`, avec sa raison, et le bilan compte les
sections ignorées à part. La compter en succès serait un mensonge, la compter en
échec rendrait `lint-k8s` rouge sans raison. Un `0 en échec` accompagné d'un
`⚠️ N section(s) ignorée(s)` dit exactement ce qui a été vérifié.

L'option `--autotest` rejoue toutes ces assertions sur des rendus volontairement
abîmés (Deployment renommé, conteneur renommé, ConfigMap fantôme, sonde sur un
port inconnu, `runAsNonRoot` retiré, image en `latest`, pull secret absent ou
mal nommé…) et vérifie qu'elles
**échouent** bien. Une assertion qui ne se déclenche jamais ne prouve rien.
L'assertion d'équivalence est auto-testée **dans les deux sens** : elle doit
tomber sur une divergence réelle, et rester silencieuse sur la seule différence
légitime, celle de `managed-by` — une comparaison rouge en permanence finit
désactivée, donc ne protège plus rien.

Variables (avec leurs valeurs par défaut) : `K8S_OVERLAYS_DIR` (`k8s/overlays`),
`HELM_CHART_DIR` (`helm/microcrm`), `APP_BACK_NAME` (`back`),
`APP_FRONT_NAME` (`front`), `REGISTRY_SECRET_NAME` (`gitlab-registry`) — les
mêmes que celles du `.gitlab-ci.yml`, pour que le contrat vérifié soit celui que
la CI déclare.
Il renvoie : `0` si tout passe, `1` si au moins une assertion échoue. Une
section ignorée ne change pas le code de sortie.

Il est écrit en **sh POSIX** et non en bash, contrairement aux autres scripts :
l'image `alpine/kubectl` n'a que busybox `sh`. Les jobs de déploiement y
installent bash (`apk add`) parce que `deploy.sh` en a réellement besoin, mais
un job de lint n'a aucune raison de dépendre d'un miroir Alpine pour tourner.

```bash
scripts/tests/validate_k8s.sh              # les assertions seules
scripts/tests/validate_k8s.sh --autotest   # + preuve qu'elles se déclenchent
```

Utilisé par **deux** jobs : `lint-k8s` (image `$KUBECTL_IMAGE`, sans helm, donc
section Helm ignorée) et `lint-helm` (image `$HELM_IMAGE`, qui a helm _et_
kubectl, donc tout est joué). Le recouvrement est assumé : chaque job reste
autonome. Le détail des manifestes est dans [K8S.md](K8S.md), celui du chart
dans [HELM.md](HELM.md).

---

## Les tests

C'est le point de vigilance « tester chaque script dans un environnement
contrôlé ». Plutôt que de le faire à la main à chaque fois, la CI le fait à
chaque commit avec le job **`test-scripts`** (stage `test`, image
`python:3.12-slim` qui fournit à la fois bash et python3).

**Comment on teste un script de déploiement sans cluster :** les vraies
commandes `kubectl`, `docker`, `trivy` et `k6` sont remplacées par de faux
programmes (dossier `tests/stubs/`) placés en premier dans le `PATH`. Le faux
`trivy` reproduit le vrai sur le point qui compte : des constats ne le font
sortir en erreur que si `--exit-code` est passé — c'est ce qui permet de
vérifier que le relevé et la porte sont deux passages distincts. Ces faux programmes
notent ce qu'on leur demande dans un fichier et renvoient le code de sortie que
le test veut. Du coup on peut vérifier :

- que chaque script renvoie le **bon code de sortie** dans chaque situation
  (paramètre manquant, secret absent, déploiement raté...) ;
- qu'il lance bien la **bonne commande** (par exemple que `rollout undo` est
  vraiment appelé quand un déploiement échoue) ;
- qu'il **ne fait rien** quand il ne doit rien faire (pas de push si le build a
  raté, pas de push si Trivy trouve une faille CRITICAL, pas de rollback si le
  déploiement s'est bien passé) ;
- qu'aucun **secret n'apparaît dans les logs**.

Pour les scripts Python, on utilise de faux rapports JaCoCo (`tests/fixtures/`),
dont un XML cassé et un rapport vide pour vérifier les cas d'erreur. Et pour
`run_k6.sh`, le faux `k6` permet de rejouer les cas qu'on ne peut pas provoquer
à la demande avec un vrai serveur : seuils dépassés, API injoignable.

Aujourd'hui : **430 tests**, tout passe (relevé du 2026-10-02). Le compte a suivi les lots successifs — 95 avant l'intégration de Terraform et d'Ansible au pipeline, 135 après, 151 avec le collecteur DORA, 266 depuis la promotion SemVer, le contrôle de versions et la notification, 430 avec l'installation de l'alerting et, avant elle, le collecteur de sécurité, les relevés Trivy (`trivy_scan.sh`, le scan avant le push), la description de release et les propriétés du pipeline qu'un lint ne voit pas (artefacts publiés même en échec, Release conditionnée aux deux promotions, mesure DORA non bloquante).

```bash
# Lancer toute la suite (rien n'est construit ni déployé)
scripts/tests/run_tests.sh
```

Les manifestes Kubernetes ont leur propre suite, `validate_k8s.sh` : elle a
besoin de `kubectl`, que l'image `$PYTHON_IMAGE` de `test-scripts` ne fournit
pas. **98 assertions** dans le job `lint-k8s` (la section Helm y étant ignorée
faute de `helm`), **174** dans `lint-helm`, qui joue en plus les contrôles du
chart et l'équivalence des deux rendus (comptes relevés le 2026-10-02).

Chaque test affiche `ok` ou `ÉCHEC` avec la raison, et le script sort en 1 si au
moins un test rate.

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
