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
│   ├── build_and_push.sh    # construit une image Docker et l'envoie au registry
│   ├── quality_gate.py      # vérifie le Quality Gate SonarCloud
│   └── check_coverage.py    # vérifie le taux de couverture des tests
├── deploy/
│   ├── deploy.sh            # déploie sur Kubernetes (avec retour arrière auto)
│   └── rollback.sh          # revient en arrière sur Kubernetes
└── tests/
    ├── run_tests.sh         # teste tous les scripts ci-dessus
    ├── run_k6.sh            # lance les tests de performance k6
    ├── fixtures/            # faux rapports JaCoCo
    └── stubs/               # faux kubectl / docker / trivy / k6
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
Il met deux tags sur l'image : le SHA du commit (fixe) et `latest`. Il peut aussi
scanner l'image avec Trivy si on ajoute `--scan`.

Options principales : `--context`, `--image`, `--tag` (obligatoires),
`--moving-tag` (défaut `latest`), `--dockerfile`, `--scan`.
Il a besoin des variables `REGISTRY_HOST`, `REGISTRY_USER`, `REGISTRY_PASSWORD`.

```bash
REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
scripts/ci/build_and_push.sh -c ./back -i "$CI_REGISTRY_IMAGE/back" -t "$CI_COMMIT_SHORT_SHA"
```

Utilisé par les jobs `package-back` et `package-front`.

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

## Les tests

C'est le point de vigilance « tester chaque script dans un environnement
contrôlé ». Plutôt que de le faire à la main à chaque fois, la CI le fait à
chaque commit avec le job **`test-scripts`** (stage `test`, image
`python:3.12-slim` qui fournit à la fois bash et python3).

**Comment on teste un script de déploiement sans cluster :** les vraies
commandes `kubectl`, `docker`, `trivy` et `k6` sont remplacées par de faux
programmes (dossier `tests/stubs/`) placés en premier dans le `PATH`. Ces faux programmes
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

Aujourd'hui : **95 tests**, tout passe.

```bash
# Lancer toute la suite (rien n'est construit ni déployé)
scripts/tests/run_tests.sh
```

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
