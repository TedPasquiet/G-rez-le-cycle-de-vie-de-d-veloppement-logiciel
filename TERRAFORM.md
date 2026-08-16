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

⚠️ **En staging, l'`apply` demande une étape préalable** : le namespace existe
déjà, créé à la main pendant la campagne du `K8S.md` §14, et Terraform ne le
connaît pas. Sans l'import du §10.1, l'exécution échoue sur
`namespaces "microcrm-staging" already exists`.

| Élément   | Version                                            |
| --------- | -------------------------------------------------- |
| Terraform | 1.15.7 (plancher déclaré : `>= 1.9`)               |
| Provider  | `hashicorp/kubernetes` 3.2.1 (contrainte `~> 3.2`) |
| Cluster   | minikube, contexte `minikube`                      |

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

**Backend `local`, un état par environnement**, dans le répertoire de
l'environnement, jamais commité.

Ce choix découle directement de la décision D2 (tout en local) : il n'existe ni
bucket, ni base, ni compte cloud pour héberger un état distant. Ce qu'il coûte,
et qu'il faut savoir défendre :

- **pas de verrou** — deux `apply` simultanés corrompraient l'état. Sans risque
  tant qu'une seule personne applique depuis un seul poste ;
- **l'état vit sur un seul poste** — le perdre oblige à réimporter les
  ressources (`terraform import`) plutôt qu'à les recréer.

Les deux états sont **séparés**, et c'est ce qui empêche une erreur de
répertoire d'emporter le mauvais environnement : avec un état unique, un
`terraform destroy` lancé dans staging aurait pu détruire la production.

**Le chemin de migration**, le jour où la CI appliquerait : GitLab héberge
gratuitement des états Terraform sur le Free Tier, via un backend `http`. La
bascule ne touche qu'un bloc :

```hcl
terraform {
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/<id>/terraform/state/<env>"
    lock_address   = "https://gitlab.com/api/v4/projects/<id>/terraform/state/<env>/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/<id>/terraform/state/<env>/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}
```

suivie d'un `terraform init -migrate-state`. Les identifiants passent par
`-backend-config`, jamais par le dépôt. Ce bloc n'est **pas** écrit dans le
projet : il porterait un identifiant de projet et donnerait l'illusion d'un état
partagé qui n'existe pas.

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

`.terraform.lock.hcl` **est versionné**, dans les deux environnements. Il fige
la version _et_ les empreintes des providers. Hors du dépôt, deux exécutions ne
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

| Absent                 | Fourni par       | Raison                                                                                                  |
| ---------------------- | ---------------- | ------------------------------------------------------------------------------------------------------- |
| `terraform.tfstate`    | rien — local     | contient en clair ce que les providers ont lu                                                           |
| Coordonnées du cluster | `~/.kube/config` | même règle que pour les manifestes (K8S.md §4)                                                          |
| `Secret` du registry   | la CI            | mot de passe, voir §3                                                                                   |
| Backend distant        | —                | aucun cloud (décision D2), voir §4                                                                      |
| Registry local         | —                | la décision D3 a retenu `minikube image load` (K8S.md §14.1) : il n'y a pas de registry local à décrire |

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

### 9.2 L'état n'a ni verrou ni sauvegarde

Voir §4. Conséquence pratique : ne pas lancer deux `apply` en parallèle, et ne
pas compter sur l'état pour reconstruire quoi que ce soit.

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

### 9.5 Rien ne relie encore Terraform au pipeline

Aucun job n'exécute `terraform`. C'est le périmètre de T6, pas de celui-ci
(§11).

## 10. Rejouer

```shell
# Prérequis : minikube démarré, contexte `minikube` courant.
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

- **T6** — jobs `terraform-validate` et `terraform-plan` sur les branches de
  fonctionnalité, `terraform-apply` en manuel comme les jobs de déploiement ;
  image d'outillage Terraform figée dans le bloc `variables:` du
  `.gitlab-ci.yml` ; stubs `terraform` dans `scripts/tests/`. C'est aussi là que
  la couture du §3 peut être refermée, en faisant lire à la CI
  `terraform output -raw namespace` au lieu de `$STAGING_NAMESPACE`.
- **T11** — schéma de la frontière : ce que Terraform crée, ce que Kustomize
  déploie, et où passe la ligne.
