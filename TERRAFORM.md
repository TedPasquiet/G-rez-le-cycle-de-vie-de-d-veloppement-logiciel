# Terraform — l'infrastructure de MicroCRM

Description de ce que Terraform possède dans ce projet, de la frontière qui le
sépare de Kustomize, de la façon dont la CI l'exécute, et de ce qu'il ne fait
pas.

Terraform décrit trois namespaces : `microcrm-staging`, `microcrm-production`
et `logging` (la stack ELK). Leurs états sont **partagés et verrouillés** (état
managé GitLab, §4). Le pipeline joue Terraform en cinq jobs (§9.5) : `validate`,
`plan` automatique et bloquant, et un `apply` manuel par environnement. L'accès
au cluster depuis la CI passe par l'**agent GitLab pour Kubernetes** (§4.1) :
aucun kubeconfig n'est stocké en variable de projet.

| Élément   | Version                                                        |
| --------- | -------------------------------------------------------------- |
| Terraform | 1.15.7 (plancher déclaré : `>= 1.5`)                           |
| Provider  | `hashicorp/kubernetes` 3.2.1 (contrainte `~> 3.2`)             |
| Cluster   | minikube, contexte `minikube` en local                         |
| État      | backend `http` — état managé GitLab, un par environnement (§4) |
| Accès CI  | agent GitLab pour Kubernetes `microcrm` (§4.1)                 |

**Les trois environnements sont appliqués**, par deux chemins :

| Environnement | Application                                                     | Date       |
| ------------- | --------------------------------------------------------------- | ---------- |
| `staging`     | depuis un poste, sur un namespace détruit (6 ressources créées) | 2026-09-22 |
| `production`  | `terraform-apply-production`, **depuis la CI**, à 07:25:32 UTC  | 2026-09-23 |
| `logging`     | depuis un poste                                                 | —          |

Les états de `staging` et de `logging`, produits en local, ont été migrés vers
l'état partagé (§4.4) ; leur plan sort à « No changes ». Ce qui reste non
vérifié est au §9.4.

## 1. Le problème que ça résout

Sans Terraform, la création d'un environnement est une commande tapée à la main
(`kubectl create namespace "$STAGING_NAMESPACE"`). Trois conséquences :

- **Le namespace n'est décrit nulle part.** Personne ne peut dire, en lisant le
  dépôt, quels environnements existent ni ce qui les distingue.
- **Aucun garde-fou de consommation.** Un back qui fuit ou un `replicas: 10`
  posé par erreur assèche le nœud, et emporte l'autre environnement avec lui.
- **Recréer un environnement n'est pas reproductible.** La procédure vit dans
  une documentation, pas dans du code exécutable.

Terraform décrit ces environnements. Le dépôt seul suffit à les recréer
(`RELEASE.md` §9.4), et `terraform plan` répond à la question « qu'est-ce qui a
bougé depuis la dernière fois ? » sans comparer des `kubectl describe` à la
main.

## 2. Pourquoi Terraform, et pas Kustomize pour tout

Kustomize sait parfaitement écrire un `Namespace` et un `ResourceQuota` — ce
sont des objets Kubernetes comme les autres. Le partage ne tient donc pas à une
limite technique, mais à un cycle de vie.

| Question               | Application            | Environnement                       |
| ---------------------- | ---------------------- | ----------------------------------- |
| Change à quel rythme ? | à chaque commit        | quelques fois par an                |
| Qui l'applique ?       | la CI, automatiquement | une personne, délibérément          |
| Que coûte une erreur ? | un rollback            | la perte du namespace, donc de tout |

Mettre les deux dans le même `kubectl apply -k` ferait passer la suppression
d'un namespace par le même chemin qu'une montée de version du front. La
séparation n'ajoute pas de sécurité magique, mais elle rend l'action grave
visible : elle demande une commande différente, dans un autre répertoire.

## 3. La frontière — la règle qui évite deux sources de vérité

C'est le point le plus important de ce document. Deux outils qui écrivent le
même objet produisent un `terraform plan` qui propose sans fin de défaire ce que
le dernier `kubectl apply` a posé.

| Objet                                           | Propriétaire  | Pourquoi                                                       |
| ----------------------------------------------- | ------------- | -------------------------------------------------------------- |
| `Namespace`                                     | **Terraform** | contenant, cycle de vie lent                                   |
| `ResourceQuota`, `LimitRange`                   | **Terraform** | garde-fous de l'environnement, pas de l'application            |
| `NetworkPolicy`                                 | **Terraform** | politique du namespace, indépendante des versions applicatives |
| `Deployment`, `Service`, `Ingress`, `ConfigMap` | **Kustomize** | change à chaque commit, appliqué par la CI                     |
| `Secret` du registry                            | **la CI**     | voir ci-dessous                                                |

La règle vaut aussi pour la stack ELK : le namespace `logging` est créé par
Terraform, ce qu'il contient par `kubectl apply -k k8s/elk`.

**Le Secret du registry ne passera jamais par Terraform.** Ce n'est pas un
oubli : `terraform.tfstate` contient en clair tout ce que les providers ont lu,
y compris les attributs marqués `sensitive` — le masquage ne vaut que pour
l'affichage. Le Secret est donc recréé par les jobs de déploiement depuis
`$CI_REGISTRY_USER` / `$CI_REGISTRY_PASSWORD` (K8S.md §12).

**Comment on lit la frontière dans le cluster.** Les ressources Terraform
portent `app.kubernetes.io/managed-by: terraform`, les ressources Kustomize
portent `managed-by: kustomize`. La question « qu'est-ce que je casse si je fais
un `destroy` ? » se répond donc sans ouvrir l'état :

```shell
kubectl get ns,resourcequota,limitrange,networkpolicy -A \
  -l app.kubernetes.io/managed-by=terraform
```

**La couture qui n'est vérifiée par rien.** Le nom du namespace existe à deux
endroits : `terraform/environments/<env>/terraform.tfvars` et la variable
GitLab `$STAGING_NAMESPACE` / `$PROD_NAMESPACE`. Rien ne compare les deux.
Terraform crée le namespace, la CI y déploie, et les deux ne se parlent pas. En
cas de divergence, le job de déploiement échoue sur un namespace inexistant — ou
pire, en crée un second, sans quota ni policy. Une variable vide, elle, fait
échouer le job (garde-fou `exige_namespace`, `RELEASE.md` §6). C'est la dette
la plus concrète de cette partie (§11).

## 4. L'état : où il vit, et pourquoi

**État managé GitLab (backend `http`), un état par environnement, verrouillé.**

Un backend `local` — un fichier par environnement sur un poste — aurait deux
défauts rédhibitoires :

- **aucun verrou** : deux `apply` simultanés corrompent l'état ;
- **un plan qui ne prouve rien** : l'état n'étant jamais commité, la CI
  repartirait d'un état vide et annoncerait « tout à créer » quel que soit le
  contenu réel du cluster. Aucune dérive ne serait détectable.

GitLab héberge gratuitement des états Terraform sur le Free Tier, sur le même
service que le dépôt. C'est ce qui est employé ici, avec **un état par
environnement** : `…/terraform/state/staging`, `…/production`, `…/logging`. La
séparation n'est pas une commodité, c'est le garde-fou qui empêche une erreur de
répertoire d'emporter le mauvais environnement — avec un état unique, un
`terraform destroy` lancé dans staging pourrait détruire la production.

**Ce qui est écrit dans le dépôt, et ce qui n'y est pas.** Le bloc `backend` de
chaque `versions.tf` ne porte que les méthodes du contrat GitLab, vraies pour
tout le monde :

```hcl
backend "http" {
  lock_method    = "POST"
  unlock_method  = "DELETE"
  retry_wait_min = 5
}
```

L'adresse et les identifiants, eux, arrivent par l'environnement. Une adresse
écrite en dur porterait l'identifiant numérique du projet GitLab — le dépôt ne
serait plus forkable ni déplaçable, et le lecteur croirait l'état attaché au
CODE alors qu'il est attaché à l'INSTANCE :

| Variable                              | En CI                                                            | Sur un poste                     |
| ------------------------------------- | ---------------------------------------------------------------- | -------------------------------- |
| `TF_STATE_BASE_URL`                   | `$CI_API_V4_URL/projects/$CI_PROJECT_ID/terraform/state`         | la même URL, projet en dur       |
| `TF_HTTP_USERNAME`                    | `gitlab-ci-token`                                                | votre identifiant GitLab         |
| `TF_HTTP_PASSWORD`                    | `$CI_JOB_TOKEN`                                                  | un jeton personnel, portée `api` |
| `TF_HTTP_ADDRESS` et les deux verrous | composées par `scripts/ci/terraform_check.sh`, par environnement |

C'est le script qui ajoute `/<environnement>` à la racine, **dans la boucle**,
avant chaque appel : un export fait une seule fois ferait écrire les trois
environnements dans le même état. C'est exactement ce que vérifie le test
« staging lit et écrit dans SON état » de `scripts/tests/run_tests.sh`, via un
faux `terraform` qui journalise `TF_HTTP_ADDRESS`.

Le jeton de job n'est pas un secret à gérer : il est émis pour un job, expire
avec lui, et ne donne accès qu'à ce projet. Rien à créer, rien à faire tourner.

Parce que l'état partagé décrit les ressources qui existent, « 0 to add » est
une information : une modification faite à la main dans le cluster apparaît en
dérive dans le plan de la merge request suivante.

**Le verrou, et qui le prend.** `apply` le prend, `plan` ne le prend pas
(`-lock=false`, posé par le script). Un plan ne persiste aucun état, il n'a rien
à protéger ; prendre le verrou ferait s'attendre les uns les autres tous les
pipelines de merge request, alors que les plans concurrents sont précisément ce
qu'une équipe produit en permanence. Côté GitLab, `resource_group` empêche en
plus deux `apply` d'un même environnement de démarrer ensemble : le verrou fait
échouer ou attendre le second, le `resource_group` l'empêche de partir.

### 4.1 Le chemin d'accès au cluster depuis la CI

**Le problème.** Le cluster du projet est un minikube, sur un poste, derrière
une box : aucune adresse joignable depuis Internet. Un kubeconfig rangé dans une
variable de projet n'y change rien — le fichier arrive dans le job, l'adresse
qu'il contient (`127.0.0.1`, qui désigne le conteneur du job lui-même) reste
injoignable. Une variable protégée serait de plus absente des branches non
protégées.

**La solution : l'agent GitLab pour Kubernetes**
(`.gitlab/agents/microcrm/config.yaml`). L'agent inverse le sens de la
connexion : il tourne DANS le cluster et ouvre une connexion **sortante** vers
GitLab ; les jobs passent par ce tunnel. Trois conséquences :

- aucun port à ouvrir, aucune API Kubernetes à exposer ;
- aucun kubeconfig à stocker en variable, donc rien à faire tourner le jour où
  quelqu'un quitte l'équipe ;
- l'accès ne dépend pas d'une variable protégée : il vaut sur les branches de
  fonctionnalité et dans les pipelines de merge request. C'est ce qui permet à
  `terraform-plan` d'être automatique.

Les jobs Terraform **et** les jobs de déploiement (`deploy-*`,
`rollback-production`) passent par ce tunnel. Aucune variable `KUBE_CONFIG`
n'est lue.

GitLab injecte `$KUBECONFIG` dans le job, **à l'exécution**. Les deux lignes qui
recollent Terraform dessus sont dans le gabarit `.terraform_infra` de
`.gitlab/ci/templates.yml`, en `before_script` et pas dans un bloc
`variables:` — qui est résolu avant le démarrage du job, donc avant que
`$KUBECONFIG` existe :

```yaml
- export TF_VAR_kubeconfig_path="$KUBECONFIG"
- export TF_VAR_kube_context="$CI_PROJECT_PATH:$KUBE_AGENT_NAME"
```

Le nom du contexte est imposé par GitLab : `<chemin du projet>:<nom de
l'agent>`. Il est recomposé, jamais écrit en dur. L'attribut `config_path` de
`providers.tf` est explicite : c'est pour cela qu'il est alimenté par une
variable Terraform, et non par la variable d'environnement `KUBECONFIG`, qu'il
ignorerait.

**Installation, une fois.**

⚠️ **Prérequis : le fichier de configuration doit être sur la branche par
défaut** (`main`). GitLab lit `.gitlab/agents/<nom>/config.yaml` sur la branche
par défaut du projet, et nulle part ailleurs : commité sur `develop` seulement,
l'agent n'apparaît pas dans la liste et son `ci_access` ne s'applique pas, sans
aucun message d'erreur.

1. `git push` de `.gitlab/agents/microcrm/` jusqu'à `main` ;
2. `kubectl apply -f .gitlab/agents/microcrm/rbac.yaml` (voir ci-dessous) ;
3. GitLab > Operate > Kubernetes clusters > Connect a cluster > `microcrm`, qui
   affiche un jeton d'enregistrement ;
4. le `helm upgrade --install` proposé, contre le contexte `minikube`, **en y
   ajoutant `--set rbac.useExistingRole=gitlab-agent-microcrm`** ;
5. l'agent doit apparaître « connected ».

La commande installée sur ce cluster — le namespace et le nom de release
viennent de la commande que GitLab affiche, et ils déterminent le nom du
ServiceAccount (`microcrm-gitlab-agent`) :

```shell
helm upgrade --install microcrm gitlab/gitlab-agent \
  --namespace gitlab-agent-microcrm --create-namespace \
  --set config.token=<jeton affiché par GitLab> \
  --set config.kasAddress=grpcs://kas.gitlab.com \
  --set rbac.useExistingRole=gitlab-agent-microcrm
```

**Les droits de l'agent dans le cluster.** Le fichier `config.yaml` dit QUI peut
emprunter le tunnel ; il ne dit pas ce que le tunnel permet de faire. Par
défaut, le chart Helm lie le ServiceAccount de l'agent à **`cluster-admin`** —
la documentation GitLab l'écrit elle-même, « for simplicity ». N'importe quel
job de CI de ce projet, sur n'importe quelle branche, pourrait alors tout faire
sur le cluster.

`.gitlab/agents/microcrm/rbac.yaml` porte donc un `ClusterRole` restreint, que
l'option `rbac.useExistingRole` substitue à `cluster-admin` :

| Objets                                                           | Droits                                                        | Pour qui                      |
| ---------------------------------------------------------------- | ------------------------------------------------------------- | ----------------------------- |
| `namespaces`, `resourcequotas`, `limitranges`, `networkpolicies` | lecture, création, modification, suppression                  | Terraform (`destroy` compris) |
| `deployments`, `services`, `configmaps`, `ingresses`             | lecture, création, modification ; **pas de suppression**      | jobs de déploiement           |
| `replicasets`                                                    | lecture seule                                                 | `rollout history` et `undo`   |
| `secrets`                                                        | `get`, `create`, `update`, `patch` ; **ni `list` ni `watch`** | le Secret du registry         |
| découverte de l'API (`/api`, `/apis`, `/version`…)               | `get`                                                         | le provider Kubernetes        |

Deux choix se lisent dans ce tableau. Un job de déploiement n'a pas le droit de
supprimer un objet applicatif : `kubectl apply -k` et `rollout undo` n'en ont
pas besoin, et un job qui peut détruire peut détruire par erreur. Et les
Secrets ne s'énumèrent pas : lire un secret dont on connaît le nom est une
chose, les parcourir tous en est une autre (risque R3 de `AUDIT.md`).

`rbac.useExistingRole` **remplace** la liaison vers `cluster-admin`, il n'ajoute
rien : ce que `cluster-admin` couvrait par accident doit être redonné
explicitement. Le chart déploie deux réplicas de l'agent, qui s'élisent un
leader au moyen d'un `Lease` et consignent le résultat dans un `Event`. Le
fichier porte donc aussi un `Role` **namespacé** (dans le namespace de l'agent
seulement) pour `leases` et `events` ; sans lui, les journaux de l'agent
répètent `leases.coordination.k8s.io … is forbidden`.

Un rôle minimal ne se vérifie pas en le lisant, mais en interrogeant le
cluster :

```shell
SA=system:serviceaccount:gitlab-agent-microcrm:microcrm-gitlab-agent
kubectl auth can-i create namespaces     --as="$SA"                     # yes
kubectl auth can-i create deployments    --as="$SA" -n microcrm-staging # yes
kubectl auth can-i delete deployments    --as="$SA" -n microcrm-staging # no
kubectl auth can-i list   secrets        --as="$SA" -A                  # no
kubectl auth can-i create clusterroles   --as="$SA"                     # no
```

Réponses relevées sur le cluster le 2026-10-06 : celles indiquées en
commentaire.

⚠️ **Limite : un seul agent, à l'échelle du cluster.** Le `ClusterRole` est lié
par un `ClusterRoleBinding` : ses droits ne sont pas bornés aux namespaces du
projet, et le même agent porte l'infrastructure et l'application. Un agent par
périmètre, chacun avec son rôle, resterait la bonne forme (§11).

⚠️ **Ce que ça coûte : `terraform-plan` est bloquant, et il parle à un cluster
qui vit sur un poste.** Minikube éteint, le job échoue et le pipeline est rouge
— l'échec est réel (personne ne peut plus rien affirmer sur la dérive), mais il
est subi. Sur un cluster qui tourne en permanence, la question ne se pose pas.
La soupape est une ligne : `allow_failure: true` sous la règle
`$CI_MERGE_REQUEST_ID` du job, qui rend le plan consultatif sans le désactiver.

### 4.2 Le plan relu, et le widget des merge requests

Un `apply` qui replanifie n'applique pas ce qui a été relu : il applique ce que
le cluster et l'état disent à l'instant où il tourne. L'écart est généralement
mince — quelques minutes, le même état verrouillé — et c'est précisément ce qui
le rend dangereux : il n'apparaît nulle part.

`--plan` enregistre donc son plan, et `--apply` applique **ce fichier** :

| Fichier            | Contenu                          | Qui le lit                             |
| ------------------ | -------------------------------- | -------------------------------------- |
| `<env>/plan.cache` | le plan binaire                  | `terraform apply plan.cache`           |
| `<env>/plan.json`  | trois entiers, par environnement | la lecture humaine, en artefact        |
| `plan-global.json` | la somme des trois               | le widget des merge requests de GitLab |

Les fichiers sont produits par environnement, publiés en artefact par
`terraform-plan`, et récupérés par les jobs d'apply via `needs:`. Quatre
détails qui ne sont pas des détails :

- **`--require-plan`**, que passent les jobs de CI : sans plan enregistré, ils
  **échouent** au lieu de replanifier. Un artefact expiré ou un job relancé seul
  ne doit pas dégrader la garantie en silence. Sur un poste, sans ce drapeau,
  l'absence de plan fait replanifier avec un avertissement — personne n'y a relu
  de plan en merge request, il n'y a rien à trahir.
- **`Saved plan is stale`** : Terraform refuse de lui-même un plan dont l'état a
  bougé depuis. C'est le comportement recherché — mieux vaut un job rouge qui
  demande de replanifier qu'un apply silencieusement différent de ce qui a été
  approuvé.
- **Un seul fichier pour le widget**, et c'est une contrainte de GitLab, pas un
  choix. Le rapport `terraform` n'accepte qu'un fichier par job ; un glob sur
  les trois résumés fait échouer l'envoi des artefacts, donc le job — alors que
  le plan, lui, a réussi :

  ```
  ERROR: Uploading artifacts as "terraform" … only one file can be sent as raw
  ```

  Deux issues sont possibles : un job de plan par environnement (trois lignes
  de widget, mais la liste des environnements écrite en dur dans le YAML), ou
  une somme. C'est la somme qui est retenue — les environnements sont découverts
  par le script (§5), et le détail par environnement reste lisible dans le
  journal du job et dans les `plan.json` publiés en artefact.

- **`access: 'developer'` sur l'artefact.** Un plan binaire embarque les valeurs
  lues dans l'état : même sensibilité que l'état lui-même. Laissé en accès
  public, il serait téléchargeable par quiconque peut voir le projet. Le JSON
  COMPLET du plan, lui, n'est jamais écrit sur le disque — `terraform show
-json` ne fait que passer dans un tube vers `jq`, qui n'en garde que trois
  entiers.

`jq` reste **facultatif** : absent, le script prévient et continue. Un widget
muet se remarque bien moins qu'un job rouge, mais il ne justifie pas de faire
échouer un plan qui, lui, a réussi.

### 4.3 Les empreintes de providers, pour toutes les plateformes

`.terraform.lock.hcl` est versionné (§5), et il porte les empreintes des quatre
plateformes qui exécutent réellement ce projet : `darwin_arm64` et
`darwin_amd64` pour les postes, `linux_amd64` et `linux_arm64` pour la CI. Un
lock qui ne couvre que le poste est complété à la volée en CI — Terraform
l'annonce par « Terraform has made some changes to the provider dependency
selections » — et un lock qui se complète tout seul ne verrouille rien : on
croit figer une version alors qu'on accepte ce que le registre propose.

```shell
terraform -chdir=terraform/environments/staging providers lock \
  -platform=darwin_arm64 -platform=darwin_amd64 \
  -platform=linux_amd64 -platform=linux_arm64
```

À rejouer dans les trois environnements à chaque changement de version de
provider, et à commiter.

### 4.4 Migrer un état local existant

Un poste qui a appliqué avec un backend local possède un `terraform.tfstate`.
Avec le bloc `backend "http"`, le prochain `init` refuse de continuer
(« Backend configuration changed ») — ce que le script rappelle en clair quand
l'init échoue. La migration se joue **une fois par environnement** :

```shell
export TF_STATE_BASE_URL='https://gitlab.com/api/v4/projects/<id>/terraform/state'
export TF_HTTP_USERNAME='<votre identifiant>'
export TF_HTTP_PASSWORD='<jeton personnel, portée api>'

for env in staging production logging; do
  export TF_HTTP_ADDRESS="$TF_STATE_BASE_URL/$env"
  export TF_HTTP_LOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
  export TF_HTTP_UNLOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
  terraform -chdir="terraform/environments/$env" init -migrate-state
done
```

Terraform prend le verrou, demande confirmation, puis pousse l'état existant
vers GitLab. Le fichier local reste sur le disque, inutilisé — le supprimer
n'est utile qu'après avoir vérifié que `terraform plan` répond « No changes ».

C'est le chemin suivi par `staging` (2026-09-22) et `logging` (2026-09-23) :
après migration, leur plan répond `No changes. Your infrastructure matches the
configuration.` Sans migration, l'état partagé croirait l'environnement vide :
un `apply` depuis la CI planifierait « 6 to add » puis échouerait sur
`already exists` (§10.1).

⚠️ **Attention à l'ordre** : migrer depuis un poste dont l'état est en retard
écraserait l'état partagé. Si plusieurs postes ont appliqué, un seul migre, les
autres suppriment leur état local avant leur premier `init`.

## 5. L'arborescence

```
terraform/
├── .gitignore                  états, plans, .terraform/ — jamais versionnés
├── modules/
│   ├── namespace/              namespace + ResourceQuota + LimitRange
│   └── network-policy/         default-deny + deux autorisations
└── environments/
    ├── staging/
    │   ├── versions.tf         versions figées + backend
    │   ├── providers.tf        coordonnées du cluster
    │   ├── variables.tf        contrat d'entrée
    │   ├── terraform.tfvars    ← la seule chose qui distingue les environnements
    │   ├── main.tf             composition des modules
    │   └── outputs.tf
    ├── production/             mêmes fichiers, autres valeurs
    └── logging/                namespace de la stack ELK + policy d'APM Server
```

Les environnements applicatifs **ne déclarent aucune ressource** : ils composent
des modules. C'est ce qui garantit que staging et production ne peuvent pas
diverger autrement que par leurs valeurs — sans quoi le premier cesserait de
valider quoi que ce soit du second.

`logging` est un namespace de plateforme, pas un environnement de
l'application. Il réutilise le module `namespace` mais **pas** le module
`network-policy`, dont les règles nomment les pods `back` et `front` : appliqué
ici, il fermerait le namespace sans rouvrir aucun flux d'ELK. Il déclare une
seule policy, `allow-microcrm-to-apm-server`, qui ne sélectionne que les pods
d'APM Server et n'admet que les namespaces applicatifs sur le port 8200.

`.terraform.lock.hcl` **est versionné**, dans les trois environnements, pour
les quatre plateformes (§4.3). Hors du dépôt, deux exécutions ne tourneraient
pas forcément avec le même code de provider — même raisonnement que les images
d'outillage figées de la CI. En revanche les modules n'ont pas de lock :
Terraform ne consulte jamais celui d'un module appelé, l'y laisser donnerait
l'illusion d'épingler quelque chose.

## 6. Ce que les modules créent

### 6.1 `modules/namespace`

Le namespace, un `ResourceQuota` et un `LimitRange`.

**Le quota est dimensionné sur le pic d'un déploiement, pas sur l'état stable.**
C'est le piège de cette ressource, et il est silencieux. Les deux Deployments
sont en `maxSurge: 1, maxUnavailable: 0` (K8S.md §6) : le nouveau pod doit être
prêt **avant** que l'ancien ne parte, il existe donc un instant où les deux
coexistent. Un quota calé sur le régime permanent laisse l'application tourner
parfaitement — et bloque le déploiement suivant sur un `exceeded quota` qui ne
dit pas qu'il s'agit d'un problème de dimensionnement. Le calcul complet, ligne
à ligne, est en commentaire dans chaque `terraform.tfvars`.

**Le `LimitRange` n'a pas de `min`.** Le front demande 10m de CPU : tout
plancher confortable à écrire le ferait rejeter, et un plancher assez bas pour
le laisser passer ne protégerait de rien.

**Son `max` est un plafond dur sur les `limits` déclarées**, pas sur la
consommation réelle : un conteneur qui le dépasse n'est pas bridé, il est
_rejeté_. Il vaut 2 CPU / 1Gi, exactement les `limits` du back de production —
le plafond est atteint, pas franchi. Toute baisse de ces valeurs doit être
vérifiée contre les `resources.limits` des manifestes `k8s/`.

Le module accepte une liste fermée de valeurs d'`environment` (`staging`,
`production`, `logging`), validée au plan : une faute de frappe échoue avant
d'atteindre le cluster.

### 6.2 `modules/network-policy`

Un refus global du trafic entrant, puis la réouverture des deux seuls flux dont
l'architecture a besoin : `ingress-nginx` → front (port 80) et `ingress-nginx` →
back (port 8080).

**Il n'y a pas de règle « front vers back », et c'est délibéré.** Le front est
une application Angular : le navigateur charge le bundle depuis le pod front,
puis appelle l'API **depuis le navigateur**, sur un hôte HTTP distinct routé par
le même contrôleur (K8S.md §7 et §13). Le flux pod front → pod back n'existe
pas. Une règle qui l'autoriserait serait sans effet, et surtout trompeuse pour
qui lit ces policies pour comprendre l'architecture.

**L'egress n'est pas restreint.** Le restreindre casserait la résolution DNS —
CoreDNS vit dans `kube-system`, hors de portée d'une règle qui ne parlerait que
du namespace applicatif — pour un gain faible : le back sert une base en
mémoire et le front des fichiers statiques. Le seul flux sortant du back est
l'envoi des traces vers APM Server, dans `logging`.

⚠️ **Ces policies sont créées mais inertes sur un minikube par défaut.**
L'application d'une NetworkPolicy appartient au CNI, pas à la ressource. Le CNI
par défaut de minikube ne l'implémente pas et ignore ces objets sans rien
signaler : l'API server les accepte, `kubectl get networkpolicy` les affiche, et
aucun paquet n'est filtré. Ce n'est pas un défaut — l'état désiré est bien celui
décrit — mais il ne faut pas conclure d'un `apply` réussi que le namespace est
cloisonné. Les règles deviennent effectives sur un CNI qui les implémente
(`minikube start --cni=calico`, ou un cluster managé), et la seule preuve qui
vaille est une tentative de connexion depuis un pod tiers.

⚠️ **À vérifier le jour où un CNI les appliquera : le sort des sondes du
kubelet.** Le kubelet interroge les pods depuis le nœud, et aucune règle
n'autorise cette source. L'usage veut que le trafic issu du nœud échappe au
filtrage, et c'est le comportement de Calico comme de Cilium, mais la
spécification NetworkPolicy ne dit rien de ce cas. C'est une hypothèse, pas un
acquis. Symptôme si elle tombe : des pods qui restent `Running` sans jamais
devenir `Ready`, et un déploiement qui expire alors que l'application va bien.

## 7. Ce qui varie entre les environnements

Tout tient dans `terraform.tfvars`. Si une différence de comportement entre les
environnements ne se lit pas ici, c'est qu'elle s'est glissée ailleurs, et
c'est un défaut.

| Réglage                    | staging            | production            | logging         |
| -------------------------- | ------------------ | --------------------- | --------------- |
| Namespace                  | `microcrm-staging` | `microcrm-production` | `logging`       |
| `pods`                     | 10                 | 20                    | 12              |
| `requests.cpu` / `.memory` | 1 / 1536Mi         | 2 / 2Gi               | 2 / 4Gi         |
| `limits.cpu` / `.memory`   | 3 / 2Gi            | 6 / 3Gi               | 6 / 6Gi         |
| `LimitRange` `max`         | 2 CPU / 1Gi        | 2 CPU / 1Gi           | 2 CPU / 2Gi     |
| NetworkPolicy              | module complet     | module complet        | APM Server seul |

Le `LimitRange` est volontairement identique entre staging et production : si
la production tolérait des conteneurs que staging refuse, staging cesserait de
valider quoi que ce soit.

## 8. Ce qui n'est pas dans le dépôt, et pourquoi

| Absent                          | Fourni par                               | Raison                                                                                                  |
| ------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `terraform.tfstate`             | l'état managé GitLab (§4)                | contient en clair ce que les providers ont lu                                                           |
| Adresse de l'état, identifiants | `TF_STATE_BASE_URL`, `TF_HTTP_*` (§4)    | l'adresse porte l'identifiant du projet GitLab : en dur, le dépôt n'est plus forkable                   |
| Coordonnées du cluster          | `~/.kube/config` en local, l'agent en CI | même règle que pour les manifestes (K8S.md §4) ; en CI, aucun kubeconfig n'est stocké (§4.1)            |
| `Secret` du registry            | la CI                                    | mot de passe, voir §3                                                                                   |
| Registry local                  | —                                        | la décision D3 a retenu `minikube image load` (K8S.md §14.1) : il n'y a pas de registry local à décrire |

**Et pourquoi pas le provider `docker`.** Le brief parle de « gestion de
ressources conteneurisées à l'aide de Terraform ». Le provider `docker` n'est
pas utilisé, pour une raison qu'il faut savoir défendre : la construction des
images appartient à la CI (`scripts/ci/build_and_push.sh`) et, en local, à
`docker compose`. Faire de Terraform un troisième chemin de build créerait un
état qui suit des identifiants d'image qu'il ne sait pas reconstruire de façon
reproductible, et deux façons concurrentes de produire la même chose. Les
« ressources conteneurisées » que gère Terraform ici sont les objets Kubernetes
qui les hébergent, pas les images elles-mêmes.

## 9. Les limites assumées

### 9.1 Il n'existe pas de cluster de production

La décision D2 a retenu l'option locale. L'environnement `production` vise donc
le même minikube, dans un autre namespace. Ce qu'il démontre : qu'un second
environnement se décrit par les mêmes modules et des valeurs différentes. Ce
qu'il ne démontre pas : qu'une production existe. Le jour où un vrai cluster
apparaît, seule change la valeur de `kube_context`.

### 9.2 L'état est verrouillé, le cluster reste sur un poste

- **L'état dépend du projet GitLab.** Perdre le projet, c'est perdre l'état — et
  donc devoir réimporter les ressources (§10.1) plutôt que les recréer. Aucune
  sauvegarde hors GitLab n'est organisée.
- **Le cluster vit sur un poste.** `terraform-plan` est bloquant et parle à ce
  cluster par le tunnel de l'agent : minikube éteint, le pipeline est rouge. La
  soupape et son coût sont décrits en §4.1.

### 9.3 Les NetworkPolicy ne filtrent rien sur ce cluster

Voir §6.2. C'est la limite la plus facile à mal présenter : le dépôt décrit un
cloisonnement, il ne le prouve pas.

### 9.4 Ce que l'`apply` a vérifié, et ce qu'il laisse ouvert

| Ce qui est vérifié                                             | Observation                                                                                                                                                                                                           |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Le quota laisse passer un déploiement complet                  | **Oui en staging** : après déploiement, `pods 2/10`, `requests.memory 544Mi/1536Mi`, `limits.memory 832Mi/2Gi` (`RELEASE.md` §9.5). **Oui dans `logging`**, observé pendant un rollout de Kibana (`MONITORING.md` §6) |
| Le `LimitRange` ne rejette aucun conteneur                     | Aucun rejet observé : les deux Deployments ont atteint leur rollout en 11 s (2026-09-22)                                                                                                                              |
| Terraform ne signale pas de dérive après un `kubectl apply -k` | `terraform plan` répond « No changes » après le déploiement de l'application (2026-09-22)                                                                                                                             |
| La gouvernance est en place                                    | les trois namespaces portent `app.kubernetes.io/managed-by=terraform` (relevé du 2026-10-06)                                                                                                                          |

Ce qui reste non vérifié :

- **`terraform-apply-staging` et `terraform-apply-logging` n'ont jamais été
  joués depuis la CI.** Leur état a été rempli depuis un poste puis migré ; leur
  plan sort à « No changes », donc le job n'aurait rien à faire.
- **La `NetworkPolicy` d'APM Server n'est pas dans le cluster.** Elle est
  décrite dans `terraform/environments/logging/main.tf`, mais
  `kubectl -n logging get networkpolicy` ne renvoie rien (relevé du 2026-10-06,
  `MONITORING.md` §10.4) : l'`apply` de `logging` est à rejouer.

### 9.5 Ce que le pipeline fait, et ne fait pas

Cinq jobs exécutent `terraform` (`.gitlab/ci/infra.yml`) :

| Job                          | Étape         | Quand                                    | Accès                         |
| ---------------------------- | ------------- | ---------------------------------------- | ----------------------------- |
| `terraform-validate`         | `infra`       | toutes branches, MR, tags                | aucun — `init -backend=false` |
| `terraform-plan`             | `infra`       | MR, `develop`, `main` — bloquant         | état partagé + cluster        |
| `terraform-apply-<env>` (×3) | `infra-apply` | `main`, **manuel**, un par environnement | état partagé + cluster        |

Les trois jobs d'apply sont manuels et **sans** `allow_failure` : un apply
interrompu laisse l'infrastructure dans un état intermédiaire, et le pipeline
doit le dire. Or un job manuel sans `allow_failure` bloque le pipeline à son
étape : placés dans `infra`, ils arrêteraient tout pipeline de `main` avant
`build`. Ils sont donc dans la dernière étape, `infra-apply`, où ils restent
bloquants sans rien retenir en amont. Ils appliquent le plan **relu**, pas un plan recalculé au
moment du clic : `terraform-plan` publie son `plan.cache` en artefact, et
`--require-plan` fait échouer l'apply s'il manque (§4.2).

Ce qui n'est pas fait : rien ne compare le nom du namespace écrit dans
`terraform.tfvars` et celui de la variable GitLab que lisent les jobs de
déploiement (§3).

## 10. Rejouer

```shell
# Prérequis : minikube démarré, contexte `minikube` courant, et les
# coordonnées de l'état partagé dans l'environnement (§4, §4.4) — sans elles,
# `init` n'a pas d'adresse de backend et échoue.
export TF_STATE_BASE_URL='https://gitlab.com/api/v4/projects/<id>/terraform/state'
export TF_HTTP_USERNAME='<votre identifiant>'
export TF_HTTP_PASSWORD='<jeton personnel, portée api>'

# Le plus simple : le script de la CI, qui compose les adresses par
# environnement et se joue à l'identique en local.
scripts/ci/terraform_check.sh --validate            # hors ligne, aucun accès
scripts/ci/terraform_check.sh --plan                # état partagé + cluster
scripts/ci/terraform_check.sh --apply -e staging    # un environnement nommé

# À la main, sur un seul environnement :
export TF_HTTP_ADDRESS="$TF_STATE_BASE_URL/staging"
export TF_HTTP_LOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
export TF_HTTP_UNLOCK_ADDRESS="$TF_HTTP_ADDRESS/lock"
cd terraform/environments/staging
terraform init      # une fois, ou après tout changement de module ou de backend
terraform validate
terraform plan      # 6 ressources à créer sur un cluster vierge, « No changes » ici
terraform apply     # demande confirmation
```

Vérifier ce qui a été créé :

```shell
kubectl get ns microcrm-staging --show-labels
kubectl describe resourcequota -n microcrm-staging
kubectl describe limitrange   -n microcrm-staging
kubectl get networkpolicy     -n microcrm-staging
```

Vérifier ensuite ce qu'un plan ne peut pas dire (§9.4) — que l'application passe
sous le quota — en enchaînant sur un déploiement (`RELEASE.md` §9.4, ou le job
`deploy-staging`).

### 10.1 ⚠️ Adopter un namespace qui existe déjà

**Cas typique : un namespace créé à la main avant Terraform**, qui porte déjà
l'application. Terraform ne sait rien de cet objet : son plan propose de le
_créer_, et l'API répond `namespaces "microcrm-staging" already exists`. C'est
le cas normal quand on introduit l'IaC sur une infrastructure existante, et il
ne se règle pas en supprimant le namespace — ce qui emporterait l'application
déployée. On le reconnaît à l'absence du label `managed-by=terraform` :

```shell
kubectl get ns microcrm-staging --show-labels
# un namespace non adopté ne porte que kubernetes.io/metadata.name=microcrm-staging
```

L'adoption se fait une fois, avant le premier `apply` :

```shell
cd terraform/environments/staging
terraform import 'module.namespace.kubernetes_namespace_v1.this' microcrm-staging
terraform plan   # doit montrer : 1 to change (les labels), 5 to add
```

Le `1 to change` est attendu et se lit : Terraform pose ses labels d'identité
sur un namespace qui n'en avait pas. Les cinq créations sont le quota, le
LimitRange et les trois policies.

Un environnement dont le namespace n'existe pas encore n'a rien à importer.

**Pourquoi pas un bloc `import` dans le code plutôt que cette commande.** Un
bloc `import` est permanent et inconditionnel : sur un cluster vierge, où
l'objet visé n'existe pas, il fait échouer le `plan` lui-même
(`Cannot import non-existent remote object`). Il transformerait une adoption
ponctuelle en dépendance durable à l'état d'un cluster précis.

Pour tout retirer :

```shell
terraform destroy   # supprime le namespace, donc TOUT ce qu'il contient
```

⚠️ **Attention : `terraform destroy` détruit le namespace**, et Kubernetes
supprime en cascade tout ce qui s'y trouve — y compris ce que Terraform n'a
jamais créé, c'est-à-dire l'application déployée par la CI. C'est la
conséquence directe du partage du §3 : Terraform possède le contenant, et
détruire un contenant emporte son contenu.

## 11. Ce qui reste à faire

- **Refermer la couture du §3** : faire lire aux jobs de déploiement
  `terraform output -raw namespace` au lieu de `$STAGING_NAMESPACE` /
  `$PROD_NAMESPACE`.
- **Un agent par périmètre.** Le rôle de l'agent `microcrm` couvre
  l'infrastructure et l'application, à l'échelle du cluster (§4.1). Un second
  agent pour les jobs de déploiement, avec un rôle lié aux seuls namespaces
  applicatifs, réduirait ce que peut un job compromis.
- **Rejouer l'`apply` de `logging`**, pour poser la policy d'APM Server, et
  jouer une fois `terraform-apply-staging` et `terraform-apply-logging` depuis
  la CI (§9.4).
- **Resserrer la fenêtre du plan relu.** `expire_in: 1 week` est un compromis :
  assez long pour un apply cliqué le lendemain, assez court pour qu'un plan
  oublié ne traîne pas. Un `apply` qui suivrait automatiquement le plan, dans le
  même pipeline, rendrait la question sans objet — au prix de la relecture
  humaine qu'on cherche justement à garder.
