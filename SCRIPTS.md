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
    ├── validate_k8s.sh      # valide les manifestes k8s/ et le chart helm/ (sans cluster)
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

## `ci/terraform_check.sh`

Contrôle les configurations Terraform de `terraform/environments/`. Trois modes,
qui n'ont ni le même coût ni la même valeur de preuve :

| Mode                  | Ce qu'il fait                                                            | Où il tourne                                      |
| --------------------- | ------------------------------------------------------------------------ | ------------------------------------------------- |
| `--validate` (défaut) | `fmt -check`, puis `init -backend=false` et `validate` par environnement | job `terraform-validate`, sur toutes les branches |
| `--plan`              | `init` puis `plan` par environnement                                     | job `terraform-plan`, manuel                      |
| `--apply`             | `init` puis `apply -auto-approve`                                        | job `terraform-apply`, manuel sur `main`          |

Les environnements sont **découverts**, jamais listés en dur : un troisième
environnement ajouté demain est contrôlé sans toucher au script. Tous sont
traités même après un échec, pour que deux erreurs se lisent en une exécution.

⚠️ **`--apply` exige `-e <environnement>`.** Appliquer en boucle sur tous les
environnements ferait passer la production dans le même geste que le staging,
sans que rien ne le distingue à la lecture du pipeline. La confirmation
interactive qu'on perd avec `-auto-approve` est remplacée par l'obligation
d'écrire l'environnement visé.

⚠️ **Ce que `--plan` ne prouve pas.** Mesuré : avec un kubeconfig valide pointant
sur un cluster éteint, `terraform plan` sort en `0` et annonce « 6 to add ». Et
comme l'état est local et jamais commité ([TERRAFORM.md](TERRAFORM.md) §4), la
CI repart d'un état vide à chaque exécution. Ce mode contrôle donc que la
configuration se résout, pas l'écart avec la réalité — le script le redit à
l'exécution, parce qu'une sortie de job se lit sans le code sous les yeux.

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

Les manifestes Kubernetes ont leur propre suite, `validate_k8s.sh` : elle a
besoin de `kubectl`, que l'image `$PYTHON_IMAGE` de `test-scripts` ne fournit
pas. **60 assertions** dans le job `lint-k8s` (dont 10 d'auto-test, la section
Helm y étant ignorée faute de `helm`), **108** dans `lint-helm`, qui joue en plus
les contrôles du chart, l'équivalence des deux rendus et ses 2 auto-tests.

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
