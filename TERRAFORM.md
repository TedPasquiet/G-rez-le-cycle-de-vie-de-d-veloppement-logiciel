# Terraform — l'infrastructure de MicroCRM

Description de ce que Terraform possède dans ce projet, de la frontière qui le
sépare de Kustomize, et de ce que cette première version ne fait pas.

**État : les configurations se construisent et se planifient, elles n'ont pas
encore été appliquées.** `terraform validate` et `terraform plan` sortent en `0`
sur les deux environnements, contre le cluster minikube réel (6 ressources à
créer de chaque côté). L'`apply` reste à jouer — voir §10 pour la commande et
§9.4 pour ce que cela laisse non vérifié. Cette distinction est maintenue tout
au long du document : ce qui a été observé est présenté comme tel, le reste est
annoncé comme non vérifié.

L'état est **partagé et verrouillé** (état managé GitLab, §4), et le pipeline
joue Terraform à quatre jobs (§9.5) : `plan` automatique et bloquant sur les
merge requests, `apply` manuel et nommé par environnement. L'accès au cluster
depuis la CI passe par l'**agent GitLab pour Kubernetes** (§4.1) — aucun
kubeconfig n'est stocké en variable de projet.

⚠️ **En staging, l'`apply` demande une étape préalable** : le namespace existe
déjà, créé à la main pendant la campagne du `K8S.md` §14, et Terraform ne le
connaît pas. Sans l'import du §10.1, l'exécution échoue sur
`namespaces "microcrm-staging" already exists`.

| Élément   | Version                                                        |
| --------- | -------------------------------------------------------------- |
| Terraform | 1.15.7 (plancher déclaré : `>= 1.5`)                           |
| Provider  | `hashicorp/kubernetes` 3.2.1 (contrainte `~> 3.2`)             |
| Cluster   | minikube, contexte `minikube` en local                         |
| État      | backend `http` — état managé GitLab, un par environnement (§4) |
| Accès CI  | agent GitLab pour Kubernetes `microcrm` (§4.1)                 |

## 1. Le problème que ça résout

Avant ce lot, la création d'un environnement se faisait à la main. `K8S.md` §10
le dit sans détour : la première étape d'un déploiement sur un cluster vierge est
`kubectl create namespace "$STAGING_NAMESPACE"`, tapé par quelqu'un. Trois
conséquences :

- **Le namespace n'était décrit nulle part.** Personne ne pouvait dire, en
  lisant le dépôt, quels environnements existent ni ce qui les distingue.
- **Aucun garde-fou de consommation.** Un back qui fuit ou un `replicas: 10`
  posé par erreur assèche le nœud, et emporte l'autre environnement avec lui.
- **Recréer un environnement n'était pas reproductible.** La procédure vivait
  dans une section de documentation, pas dans du code exécutable.

Terraform décrit maintenant ces environnements. Le dépôt seul suffit à les
recréer, et `terraform plan` répond à la question « qu'est-ce qui a bougé depuis
la dernière fois ? » sans avoir à comparer des `kubectl describe` à la main.

## 2. Pourquoi Terraform, et pas Kustomize pour tout

Kustomize sait parfaitement écrire un `Namespace` et un `ResourceQuota` — ce
sont des objets Kubernetes comme les autres. Le partage ne tient donc pas à une
limite technique, mais à un cycle de vie.

|                        | Application            | Environnement                       |
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

**Le Secret du registry ne passera jamais par Terraform.** Ce n'est pas un
oubli : `terraform.tfstate` contient en clair tout ce que les providers ont lu,
y compris les attributs marqués `sensitive` — le masquage ne vaut que pour
l'affichage. Le Secret continue donc d'être recréé par les jobs de déploiement
depuis `$CI_REGISTRY_USER` / `$CI_REGISTRY_PASSWORD` (K8S.md §12).

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
pire, en crée un second, sans quota ni policy. C'est la dette la plus concrète
de ce lot ; la refermer est du ressort de T6 (§11).

## 4. L'état : où il vit, et pourquoi

**État managé GitLab (backend `http`), un état par environnement, verrouillé.**

Ce n'était pas le choix d'origine. Le projet a démarré en backend `local`, un
fichier par environnement sur un seul poste — ce que la décision D2 (tout en
local) rendait naturel, faute de bucket ou de compte cloud. Deux défauts ont
imposé la bascule dès que le dépôt a été ouvert à plusieurs personnes :

- **aucun verrou** : deux `apply` simultanés corrompaient l'état. Sans risque
  tant qu'une seule personne appliquait depuis un seul poste, certain d'arriver
  à deux ;
- **un plan qui ne prouvait rien** : l'état n'étant jamais commité, la CI
  repartait d'un état VIDE et annonçait « tout à créer » quel que soit le
  contenu réel du cluster. Le job `terraform-plan` ne pouvait structurellement
  détecter aucune dérive — il était d'ailleurs en `manual` + `allow_failure`.

GitLab héberge gratuitement des états Terraform sur le Free Tier, sur le même
service que le dépôt. C'est ce qui est employé ici, avec **un état par
environnement** : `…/terraform/state/staging`, `…/production`, `…/logging`. La
séparation n'est pas une commodité, c'est le garde-fou qui empêche une erreur de
répertoire d'emporter le mauvais environnement — avec un état unique, un
`terraform destroy` lancé dans staging aurait pu détruire la production.

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

⚠️ **Ce que le premier plan affichera, et pourquoi ce n'est pas le défaut
d'avant.** L'`apply` n'a jamais été joué (§9.4) : l'état partagé démarre donc
vide, et le plan annoncera « 6 to add » sur chaque environnement. La sortie
ressemble à celle d'avant la bascule, la différence est entière — avant, l'état
repartait de zéro **à chaque exécution** et aucun apply n'aurait pu y changer
quoi que ce soit ; maintenant, l'état persiste, et le premier
`terraform-apply-<env>` le remplit une fois pour toutes. C'est à partir de là
que « 0 to add » devient une information, et qu'une modification faite à la main
dans le cluster apparaît en dérive dans le plan de la merge request suivante.

**Le verrou, et qui le prend.** `apply` le prend, `plan` ne le prend pas
(`-lock=false`, posé par le script). Un plan ne persiste aucun état, il n'a rien
à protéger ; prendre le verrou ferait s'attendre les uns les autres tous les
pipelines de merge request, alors que les plans concurrents sont précisément ce
qu'une équipe produit en permanence. Côté GitLab, `resource_group` empêche en
plus deux `apply` d'un même environnement de démarrer ensemble : le verrou fait
échouer ou attendre le second, le `resource_group` l'empêche de partir.

### 4.1 Le chemin d'accès au cluster depuis la CI

L'état partagé ne suffisait pas à rendre `terraform-plan` utilisable : encore
faut-il que le runner atteigne le cluster. Il ne l'atteignait pas, et l'échec
était lisible :

```
Error: Invalid attribute in provider configuration
  on providers.tf line 8, in provider "kubernetes":
'config_path' refers to an invalid path: "/root/.kube/config"
```

Trois causes empilées, chacune suffisante :

1. l'image d'outillage tourne en `root` : `~/.kube/config` s'y résout en
   `/root/.kube/config`, qui n'existe pas ;
2. le `KUBECONFIG: $KUBE_CONFIG` que portait le job n'était de toute façon
   **jamais lu par Terraform**, dont le `config_path` est explicite dans
   `providers.tf` — une variable d'environnement ne peut pas gagner contre un
   attribut écrit ;
3. le contexte visé, `minikube`, n'existe dans aucun kubeconfig de CI.

Et une quatrième, indépendante : `$KUBE_CONFIG` est une variable **protégée**,
donc absente des branches non protégées.

**Ce qui est employé à la place : l'agent GitLab pour Kubernetes**
(`.gitlab/agents/microcrm/config.yaml`). Le cluster du projet est un minikube,
sur un poste, derrière une box : aucune adresse joignable depuis Internet. Un
kubeconfig rangé dans une variable n'y changeait rien — le fichier arrivait bien
dans le job, l'adresse qu'il contenait restait injoignable. L'agent inverse le
sens de la connexion : il tourne DANS le cluster et ouvre une connexion
**sortante** vers GitLab ; les jobs passent par ce tunnel. Trois conséquences :

- aucun port à ouvrir, aucune API Kubernetes à exposer ;
- aucun kubeconfig à stocker en variable, donc rien à faire tourner le jour où
  quelqu'un quitte l'équipe ;
- l'accès ne dépend plus d'une variable protégée : il vaut sur les branches de
  fonctionnalité et dans les pipelines de merge request. C'est ce qui permet à
  `terraform-plan` d'être automatique.

GitLab injecte alors `$KUBECONFIG` dans le job, **à l'exécution**. Les deux
lignes qui recollent Terraform dessus sont dans le gabarit `.terraform_infra` du
`.gitlab-ci.yml`, en `before_script` et pas dans un bloc `variables:` — qui est
résolu avant le démarrage du job, donc avant que `$KUBECONFIG` existe :

```yaml
- export TF_VAR_kubeconfig_path="$KUBECONFIG"
- export TF_VAR_kube_context="$CI_PROJECT_PATH:$KUBE_AGENT_NAME"
```

Le nom du contexte est imposé par GitLab : `<chemin du projet>:<nom de
l'agent>`. Il est recomposé, jamais écrit en dur.

**Installation, une fois.**

⚠️ **Le fichier de configuration doit être sur la branche par défaut** (`main`).
GitLab lit `.gitlab/agents/<nom>/config.yaml` sur la branche par défaut du
projet, et nulle part ailleurs : commité sur `develop` seulement, l'agent
n'apparaît pas dans la liste et son `ci_access` ne s'applique pas. C'est le
premier piège de cette installation, et il ne produit aucun message d'erreur —
seulement un agent absent du menu.

1. `git push` de `.gitlab/agents/microcrm/` jusqu'à `main` ;
2. `kubectl apply -f .gitlab/agents/microcrm/rbac.yaml` (voir ci-dessous) ;
3. GitLab > Operate > Kubernetes clusters > Connect a cluster > `microcrm`, qui
   affiche un jeton d'enregistrement ;
4. le `helm upgrade --install` proposé, contre le contexte `minikube`, **en y
   ajoutant `--set rbac.useExistingRole=gitlab-agent-microcrm`** ;
5. l'agent doit apparaître « connected ».

**Les droits de l'agent dans le cluster — l'étape qu'on oublie.** Le fichier
`config.yaml` dit QUI peut emprunter le tunnel ; il ne dit pas ce que le tunnel
permet de faire. Par défaut, le chart Helm lie le ServiceAccount de l'agent à
**`cluster-admin`** — la documentation GitLab l'écrit elle-même, « for
simplicity ». Autrement dit : n'importe quel job de CI de ce projet, sur
n'importe quelle branche, pourrait tout faire sur le cluster, alors que les
seuls jobs qui passent par l'agent manipulent quatre types d'objets.

`.gitlab/agents/microcrm/rbac.yaml` porte donc un `ClusterRole` restreint à ces
quatre types (`namespaces`, `resourcequotas`, `limitranges`,
`networkpolicies`), plus la découverte de l'API, et l'option
`rbac.useExistingRole` le substitue à `cluster-admin`. Le contrôle qui vaut
n'est pas la lecture du fichier mais l'interrogation du cluster :

```shell
SA=system:serviceaccount:gitlab-agent:microcrm-gitlab-agent
kubectl auth can-i create namespaces  --as="$SA"   # yes
kubectl auth can-i create deployments --as="$SA"   # no  ← le but
kubectl auth can-i get secrets -A     --as="$SA"   # no  ← le but
```

Ce rôle ne couvre pas les objets applicatifs : les jobs de déploiement passent
encore par `$KUBE_CONFIG`, pas par l'agent. Le jour où ils basculeront sur le
tunnel — souhaitable, pour les mêmes raisons — le bon geste sera un **second
agent avec son propre rôle**, plutôt qu'un rôle unique qui grossit.

⚠️ **Ce que ça coûte, et qu'il faut savoir défendre** : `terraform-plan` est
bloquant, et il parle à un cluster qui vit sur un poste. Minikube éteint, le job
échoue et le pipeline est rouge — l'échec est réel (personne ne peut plus rien
affirmer sur la dérive), mais il est subi. Sur un cluster qui tourne en
permanence, la question ne se pose pas. Tant que ce n'est pas le cas, la
soupape est une ligne : `allow_failure: true` sous la règle
`$CI_MERGE_REQUEST_ID` du job, qui rend le plan consultatif sans le désactiver.

### 4.2 Le plan relu, et le widget des merge requests

Un `apply` qui replanifie n'applique pas ce qui a été relu : il applique ce que
le cluster et l'état disent à l'instant où il tourne. L'écart est généralement
mince — quelques minutes, le même état verrouillé — et c'est précisément ce qui
le rend dangereux : il n'apparaît nulle part.

`--plan` enregistre donc son plan, et `--apply` applique **ce fichier** :

| Fichier      | Contenu                              | Qui le lit                             |
| ------------ | ------------------------------------ | -------------------------------------- |
| `plan.cache` | le plan binaire                      | `terraform apply plan.cache`           |
| `plan.json`  | trois entiers (create/update/delete) | le widget des merge requests de GitLab |

Les deux sont produits par environnement, publiés en artefact par
`terraform-plan`, et récupérés par les jobs d'apply via `needs:`. Trois détails
qui ne sont pas des détails :

- **`--require-plan`**, que passent les jobs de CI : sans plan enregistré, ils
  **échouent** au lieu de replanifier. Un artefact expiré ou un job relancé seul
  ne doit pas dégrader la garantie en silence. Sur un poste, sans ce drapeau,
  l'absence de plan fait replanifier avec un avertissement — personne n'y a relu
  de plan en merge request, il n'y a rien à trahir.
- **`Saved plan is stale`** : Terraform refuse de lui-même un plan dont l'état a
  bougé depuis. C'est le comportement recherché — mieux vaut un job rouge qui
  demande de replanifier qu'un apply silencieusement différent de ce qui a été
  approuvé.
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

`.terraform.lock.hcl` est versionné (§5), mais il ne l'était utilement que pour
le poste : il ne contenait qu'une empreinte `h1:`, celle de `darwin_arm64`. En
CI, sur `linux_amd64`, Terraform le disait à chaque exécution —

```
Terraform has made some changes to the provider dependency selections recorded
in the .terraform.lock.hcl file.
```

— et complétait le fichier à la volée. Un lock qui se complète tout seul ne
verrouille rien : c'est le cas où l'on croit figer une version alors qu'on
accepte ce que le registre propose. Les quatre plateformes qui exécutent
réellement ce projet y sont donc inscrites :

```shell
terraform -chdir=terraform/environments/staging providers lock \
  -platform=darwin_arm64 -platform=darwin_amd64 \
  -platform=linux_amd64 -platform=linux_arm64
```

À rejouer dans les trois environnements à chaque changement de version de
provider, et à commiter.

### 4.4 Migrer un état local existant

Un poste qui a déjà appliqué possède un `terraform.tfstate` local. Le bloc
`backend` ayant changé, le prochain `init` refuse de continuer (« Backend
configuration changed ») — ce que le script rappelle en clair quand l'init
échoue. La migration se joue **une fois par environnement** :

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

Terraform demande confirmation, puis pousse l'état existant vers GitLab. Le
fichier local reste sur le disque, désormais inutilisé — le supprimer n'est utile
qu'après avoir vérifié que `terraform plan` ne propose plus de tout recréer.

⚠️ **À ne pas faire dans le désordre** : migrer depuis un poste dont l'état est
en retard écraserait l'état partagé. Si plusieurs postes ont appliqué, un seul
migre, les autres suppriment leur état local avant leur premier `init`.

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
    └── production/             mêmes fichiers, autres valeurs
```

Les environnements **ne déclarent aucune ressource** : ils composent des
modules. C'est ce qui garantit que staging et production ne peuvent pas diverger
autrement que par leurs valeurs — sans quoi le premier cesserait de valider quoi
que ce soit du second.

`.terraform.lock.hcl` **est versionné**, dans les trois environnements. Il fige
la version _et_ les empreintes des providers, pour les quatre plateformes qui
exécutent ce projet (§4.3 — un lock qui ne couvre que le poste se laisse
compléter en CI, donc ne verrouille rien). Hors du dépôt, deux exécutions ne
tourneraient pas forcément avec le même code de provider — même raisonnement que
les images d'outillage figées du `.gitlab-ci.yml`. En revanche les modules n'ont
pas de lock : Terraform ne consulte jamais celui d'un module appelé, l'y laisser
donnerait l'illusion d'épingler quelque chose.

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
du namespace applicatif — pour un gain nul : le back sert une base en mémoire et
le front des fichiers statiques, aucun des deux n'émet d'appel sortant qu'on
chercherait à contenir.

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
deux environnements ne se lit pas ici, c'est qu'elle s'est glissée ailleurs, et
c'est un défaut.

|                            | staging            | production            |
| -------------------------- | ------------------ | --------------------- |
| Namespace                  | `microcrm-staging` | `microcrm-production` |
| `pods`                     | 10                 | 20                    |
| `requests.cpu` / `.memory` | 1 / 1536Mi         | 2 / 2Gi               |
| `limits.cpu` / `.memory`   | 3 / 2Gi            | 6 / 3Gi               |
| LimitRange                 | identique          | identique             |
| NetworkPolicy              | actives            | actives               |

Le `LimitRange` est volontairement identique : si la production tolérait des
conteneurs que staging refuse, staging cesserait de valider quoi que ce soit.

## 8. Ce qui n'est pas dans le dépôt, et pourquoi

| Absent                          | Fourni par                               | Raison                                                                                                  |
| ------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `terraform.tfstate`             | l'état managé GitLab (§4)                | contient en clair ce que les providers ont lu                                                           |
| Adresse de l'état, identifiants | `TF_STATE_BASE_URL`, `TF_HTTP_*` (§4)    | l'adresse porte l'identifiant du projet GitLab : en dur, le dépôt n'est plus forkable                   |
| Coordonnées du cluster          | `~/.kube/config` en local, l'agent en CI | même règle que pour les manifestes (K8S.md §4) ; en CI, aucun kubeconfig n'est stocké (§4.1)            |
| `Secret` du registry            | la CI                                    | mot de passe, voir §3                                                                                   |
| Registry local                  | —                                        | la décision D3 a retenu `minikube image load` (K8S.md §14.1) : il n'y a pas de registry local à décrire |

**Et pourquoi pas le provider `docker`.** La feuille de route l'évoquait, et le
brief parle de « gestion de ressources conteneurisées à l'aide de Terraform ».
Il n'est pas utilisé, pour une raison qu'il faut savoir défendre : la
construction des images appartient à la CI (`scripts/ci/build_and_push.sh`) et,
en local, à `docker compose`. Faire de Terraform un troisième chemin de build
créerait un état qui suit des identifiants d'image qu'il ne sait pas
reconstruire de façon reproductible, et deux façons concurrentes de produire la
même chose. Les « ressources conteneurisées » que gère Terraform ici sont les
objets Kubernetes qui les hébergent, pas les images elles-mêmes.

## 9. Les limites assumées

### 9.1 Il n'existe pas de cluster de production

La décision D2 a retenu l'option locale. L'environnement `production` vise donc
le même minikube, dans un autre namespace. Ce qu'il démontre : qu'un second
environnement se décrit par les mêmes modules et des valeurs différentes. Ce
qu'il ne démontre pas : qu'une production existe. Le jour où un vrai cluster
apparaît, seule change la valeur de `kube_context`.

### 9.2 L'état est verrouillé, le cluster reste sur un poste

Le défaut d'origine — un état local, sans verrou, qui rendait tout plan de CI
muet sur la dérive — est corrigé : §4. Ce qui reste, et qu'il faut savoir dire :

- **l'état dépend du projet GitLab.** Il n'est plus sur un poste, il est chez
  GitLab. Perdre le projet, c'est perdre l'état — et donc devoir réimporter les
  ressources (§10.1) plutôt que les recréer. Aucune sauvegarde hors GitLab n'est
  organisée ;
- **le cluster, lui, vit toujours sur un poste.** `terraform-plan` est bloquant
  et parle à ce cluster par le tunnel de l'agent : minikube éteint, le pipeline
  est rouge. La soupape et son coût sont décrits en §4.1.

### 9.3 Les NetworkPolicy ne filtrent rien sur ce cluster

Voir §6.2. C'est la limite la plus facile à mal présenter en soutenance : le lot
décrit un cloisonnement, il ne le prouve pas.

### 9.4 L'`apply` n'a pas été joué

`validate` et `plan` sont vérifiés, `apply` ne l'est pas. Restent donc non
vérifiés, et à confirmer par la commande du §10 :

- que le quota laisse effectivement passer un déploiement complet — c'est le
  risque identifié au §6.1, et un plan ne peut pas le trancher : un `Deployment`
  ne consomme pas de quota, seuls ses pods en consomment ;
- que le `LimitRange` n'en rejette aucun conteneur ;
- que Terraform ne signale pas de dérive après un `kubectl apply -k` de la CI.

### 9.5 Ce que le pipeline fait, et ne fait pas

Quatre jobs exécutent `terraform` (`.gitlab-ci.yml`, étape `infra`) :

| Job                          | Quand                            | Accès                         |
| ---------------------------- | -------------------------------- | ----------------------------- |
| `terraform-validate`         | toutes branches, MR, tags        | aucun — `init -backend=false` |
| `terraform-plan`             | MR, `develop`, `main` — bloquant | état partagé + cluster        |
| `terraform-apply-<env>` (×3) | `main`, **manuel**               | état partagé + cluster        |

Les trois jobs d'apply appliquent le plan **relu**, pas un plan recalculé au
moment du clic : `terraform-plan` publie son `plan.cache` en artefact, et
`--require-plan` fait échouer l'apply s'il manque (§4.2).

Ce qui n'est pas fait, et qui reste la suite utile : **les jobs de déploiement ne
passent pas par l'agent.** `deploy-staging` et `deploy-production` utilisent
encore `$KUBE_CONFIG`, une variable protégée qui porte un kubeconfig — donc tout
ce que §4.1 reproche à cette approche vaut encore pour eux. Ils n'ont simplement
jamais été exercés contre un cluster joignable depuis la CI.

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
terraform plan      # 6 ressources à créer sur un cluster vierge
terraform apply     # demande confirmation
```

### 10.1 ⚠️ Adopter un namespace qui existe déjà

**Sur ce poste, `terraform apply` échouerait en staging tel quel.** Le namespace
`microcrm-staging` existe depuis la campagne de déploiement du `K8S.md` §14, il
porte l'application en marche, et il n'a jamais été créé par Terraform :

```
$ kubectl get ns microcrm-staging --show-labels
NAME               STATUS   AGE    LABELS
microcrm-staging   Active   5d3h   kubernetes.io/metadata.name=microcrm-staging
```

Terraform ne sait rien de cet objet : son plan propose de le _créer_, et l'API
répondrait `namespaces "microcrm-staging" already exists`. C'est le cas normal
quand on introduit l'IaC sur une infrastructure existante, et il ne se règle pas
en supprimant le namespace — ce qui emporterait l'application déployée.

L'adoption se fait une fois, avant le premier `apply` :

```shell
cd terraform/environments/staging
terraform import 'module.namespace.kubernetes_namespace_v1.this' microcrm-staging
terraform plan   # doit désormais montrer : 1 to change (les labels), 5 to add
```

Le `1 to change` est attendu et se lit : Terraform pose ses labels d'identité
sur un namespace qui n'en avait pas. Les cinq créations sont le quota, le
LimitRange et les trois policies.

Un environnement dont le namespace n'existe pas encore — la production, ici —
n'a rien à importer.

**Pourquoi pas un bloc `import` dans le code plutôt que cette commande.** Un
bloc `import` est permanent et inconditionnel : sur un cluster vierge, où
l'objet visé n'existe pas, il fait échouer le `plan` lui-même
(`Cannot import non-existent remote object`). Il transformerait une adoption
ponctuelle en dépendance durable à l'état d'un cluster précis.

Vérifier ce qui a été créé :

```shell
kubectl get ns microcrm-staging --show-labels
kubectl describe resourcequota -n microcrm-staging
kubectl describe limitrange   -n microcrm-staging
kubectl get networkpolicy     -n microcrm-staging
```

Vérifier ensuite ce qu'un plan ne peut pas dire (§9.4) — que l'application passe
sous le quota — en enchaînant sur le déploiement décrit dans `K8S.md` §14.9.

Pour tout retirer :

```shell
terraform destroy   # supprime le namespace, donc TOUT ce qu'il contient
```

⚠️ `terraform destroy` détruit le namespace, et Kubernetes supprime en cascade
tout ce qui s'y trouve — y compris ce que Terraform n'a jamais créé, c'est-à-dire
l'application déployée par la CI. C'est la conséquence directe du partage du §3 :
Terraform possède le contenant, et détruire un contenant emporte son contenu.

## 11. La suite

- **T6 — fait.** Les quatre jobs de l'étape `infra` sont en place (§9.5), avec
  l'état partagé (§4) et l'agent Kubernetes (§4.1). Reste la couture du §3 : la
  CI lit encore `$STAGING_NAMESPACE` au lieu de `terraform output -raw
namespace`.
- **Faire passer les jobs de déploiement par l'agent**, avec leur propre agent
  et leur propre rôle : `deploy-staging` et `deploy-production` s'appuient encore
  sur un kubeconfig en variable protégée (§9.5). Un agent par périmètre vaut
  mieux qu'un rôle qui grossit — le rôle de `microcrm` est délibérément limité
  aux quatre types d'objets de Terraform (§4.1).
- **Resserrer la fenêtre du plan relu.** `expire_in: 1 week` est un compromis :
  assez long pour un apply cliqué le lendemain, assez court pour qu'un plan
  oublié ne traîne pas. Un `apply` qui suivrait automatiquement le plan, dans le
  même pipeline, rendrait la question sans objet — au prix de la relecture
  humaine qu'on cherche justement à garder.
- **T11** — schéma de la frontière : ce que Terraform crée, ce que Kustomize
  déploie, et où passe la ligne.
