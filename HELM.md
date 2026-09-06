# Helm — le chart MicroCRM

Le dépôt décrit son déploiement **deux fois** : en overlays Kustomize
(`k8s/`, voir [K8S.md](K8S.md)) et en chart Helm (`helm/microcrm/`). Ce document
dit ce que le second apporte, ce qu'il duplique du premier, et — la seule
question qui compte quand deux descriptions coexistent — **lequel fait foi**.

**État : le chart se rend, se lint, et son rendu est prouvé identique à celui de
Kustomize.** Il n'a jamais déployé quoi que ce soit.

| Vérification                                                            | Résultat            |
| ----------------------------------------------------------------------- | ------------------- |
| `helm lint`, avec chacun des deux jeux de valeurs                       | `0 chart(s) failed` |
| Rendu staging ≡ rendu Kustomize staging                                 | identique           |
| Rendu production ≡ rendu Kustomize production                           | identique           |
| Rendu sans `-f` ≡ `kubectl kustomize k8s/base`                          | identique           |
| `helm template … \| kubectl apply --dry-run=server -n microcrm-staging` | `0`                 |

## 1. Pourquoi ce chart existe

Le brief du projet nomme Helm deux fois et le liste dans les outils attendus. Le
dépôt avait choisi Kustomize, avec une justification écrite ([K8S.md](K8S.md) §2)
et une soixantaine d'assertions de test qui en dépendent. Trois issues étaient
possibles : migrer vers Helm, assumer l'écart, ou ajouter le chart.

C'est la troisième qui a été retenue, et elle a un coût qu'il faut nommer :
**deux descriptions de la même application, c'est deux occasions de diverger.**
Tout ce qui suit — et en particulier le contrôle d'équivalence du §6 — existe
pour que cette divergence soit impossible à commettre en silence.

## 2. Ce que le chart duplique, exactement

Tout. Le chart n'ajoute aucun objet, n'en retire aucun, et ne change aucune
valeur. Il produit les six mêmes objets :

| Objet      | Nom               | Source Kustomize             |
| ---------- | ----------------- | ---------------------------- |
| ConfigMap  | `microcrm-config` | `k8s/base/configmap.yaml`    |
| Service    | `back`, `front`   | `k8s/base/*-service.yaml`    |
| Deployment | `back`, `front`   | `k8s/base/*-deployment.yaml` |
| Ingress    | `microcrm`        | `k8s/base/ingress.yaml`      |

**La seule différence est le label `app.kubernetes.io/managed-by`** : `kustomize`
d'un côté, `Helm` de l'autre.

La majuscule de `Helm` n'est pas un choix de style. Helm **réécrit** ce label sur
tout objet qu'il applique, quelle que soit la valeur écrite dans le chart, et il
y ajoute deux annotations. Vérifié en installant le chart dans un namespace
jetable :

```
$ kubectl -n microcrm-helm-probe get cm microcrm-config -o jsonpath='{.metadata.labels}'
{"app.kubernetes.io/environment":"staging","app.kubernetes.io/instance":"microcrm-staging",
 "app.kubernetes.io/managed-by":"Helm","app.kubernetes.io/part-of":"microcrm"}

$ kubectl -n microcrm-helm-probe get cm microcrm-config -o jsonpath='{.metadata.annotations}'
{"meta.helm.sh/release-name":"probe","meta.helm.sh/release-namespace":"microcrm-helm-probe"}
```

Rendre `helm` en minuscules aurait donné un manifeste qui ne décrit pas l'objet
réellement déployé.

## 3. Lequel fait foi : **Kustomize**

Sans ambiguïté, et pour des raisons vérifiables :

1. **C'est Kustomize qui déploie.** Les jobs `deploy-staging` et
   `deploy-production` exécutent `kubectl apply -k`. Aucun job n'exécute
   `helm upgrade`.
2. **Le mécanisme qui corrige le rollback est propre à Kustomize.** L'overlay
   éphémère qui pose l'image réelle _avant_ l'`apply` ([K8S.md](K8S.md) §6)
   s'appuie sur le transformateur `images:`. C'est lui qui a supprimé la
   révision « placeholder » qui rendait `rollback-production` destructeur. Le
   chart offre l'équivalent par `--set image.tag`, mais il n'a jamais été
   éprouvé sur un cluster.
3. **Le chart n'a jamais rien déployé.** Kustomize, si — campagne complète
   consignée en [K8S.md](K8S.md) §14.

Le chart répond à l'exigence du brief et prouve que le déploiement est
portable d'un outil à l'autre. Il ne remplace rien.

### Les deux mécanismes ne peuvent pas cohabiter sur un même namespace

Ce n'est pas une précaution théorique, c'est un refus explicite de Helm.
Observé sur le namespace `microcrm-staging`, déployé par Kustomize :

```
$ helm upgrade --install microcrm helm/microcrm \
    -f helm/microcrm/values-staging.yaml -n microcrm-staging --dry-run=server

Error: unable to continue with install: ConfigMap "microcrm-config" in namespace
"microcrm-staging" exists and cannot be imported into the current release:
invalid ownership metadata; label validation error: key
"app.kubernetes.io/managed-by" must equal "Helm": current value is "kustomize";
annotation validation error: missing key "meta.helm.sh/release-name" …
```

Helm refuse d'adopter des objets qu'il n'a pas créés. Basculer un environnement
existant de Kustomize vers Helm demanderait donc de poser à la main le label et
les deux annotations sur chaque objet — ou de tout supprimer et réinstaller.
C'est la démonstration la plus concrète qu'il faut **un seul** mécanisme par
environnement, et que le choix se fait avant le premier déploiement, pas après.

## 4. Ce que `values.yaml` expose, et ce qu'il n'expose pas

La règle appliquée : **exactement ce qui varie entre les overlays, ni plus ni
moins.** Un paramètre exposé est une invitation à le diverger.

| Exposé                          | Pourquoi                                                        |
| ------------------------------- | --------------------------------------------------------------- |
| `environment`                   | pilote les labels `instance` et `environment`                   |
| `front.replicas`                | 1 en staging, 2 en production                                   |
| `back.resources`                | la production les relève                                        |
| `config.*`                      | les deux clés de la ConfigMap                                   |
| `ingress.frontHost` / `apiHost` | les hôtes changent par environnement                            |
| `image.repository` / `tag`      | ne varient pas par environnement mais par exécution de pipeline |

| Non exposé                       | Pourquoi                                                                                                                                                                                                                        |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`back.replicas`**              | ⚠️ vaut 1 partout et doit le rester : HSQLDB vit dans la mémoire du processus, deux pods donneraient deux jeux de données divergents sans qu'aucune erreur ne soit levée ([K8S.md](K8S.md) §8.1). Écrit en dur dans le template |
| ports, sondes, `securityContext` | identiques partout ; les exposer n'apporterait qu'un moyen de les affaiblir                                                                                                                                                     |
| nom du pull secret               | contractuel avec `$REGISTRY_SECRET_NAME` de la CI                                                                                                                                                                               |
| le namespace                     | fourni à l'exécution, comme pour Kustomize ([K8S.md](K8S.md) §4)                                                                                                                                                                |

Les valeurs par défaut de `values.yaml` reproduisent la **base** Kustomize —
hôtes en `.invalid`, URL en `localhost`, image `microcrm/back:PLACEHOLDER`.
Conséquence utile : `helm template` fonctionne sans aucune coordonnée de
registry, exactement comme `kubectl kustomize`, et le job de lint n'a besoin
d'aucun secret.

## 5. Les réflexes Helm délibérément refusés

Ce sont les points qu'un relecteur habitué à Helm signalera comme des erreurs.
Ce n'en sont pas.

**Aucun préfixe de nom de release.** Pas de helper `fullname`, pas de
`{{ .Release.Name }}-back`. Les objets s'appellent littéralement `back` et
`front`, parce que `scripts/deploy/deploy.sh` exécute
`kubectl set image deployment/back back=<image>`. Un préfixe casserait le
déploiement au premier `set image`, avec un message peu parlant. C'est
exactement la raison pour laquelle les overlays Kustomize se passent aussi de
`namePrefix`. Corollaire assumé : deux releases du chart dans le **même**
namespace entreraient en collision — sans objet ici, un namespace valant un
environnement.

**`spec.selector.matchLabels` ne porte que `app.kubernetes.io/name`.** Pas
d'`instance`. Le sélecteur d'un Deployment est immuable après création : y
ajouter un label ferait échouer toute mise à jour d'un environnement déjà
déployé. C'est ce que dit `k8s/base/kustomization.yaml` à propos
d'`includeSelectors`.

**Aucun `namespace:` dans les templates**, ni `{{ .Release.Namespace }}`. Le
namespace est une coordonnée d'infrastructure, il arrive par `-n`.

**Aucun `NOTES.txt`, aucun test Helm, aucune dépendance.** Le chart décrit un
déploiement, il n'enseigne rien à personne.

## 6. Comment la divergence est empêchée

Deux descriptions ne restent d'accord que si quelque chose le vérifie à chaque
commit. C'est le rôle du job **`lint-helm`** (stage `lint`, image
`$HELM_IMAGE`), qui enchaîne trois contrôles de force croissante :

1. `helm lint`, sur **chacun** des deux jeux de valeurs — un chart peut se
   rendre avec ceux de staging et échouer avec ceux de production ;
2. les assertions de `scripts/tests/validate_k8s.sh` rejouées sur le rendu du
   chart : contrat de nommage avec `deploy.sh`, socle de sécurité, tags figés,
   pull secret ;
3. **la comparaison des deux rendus, objet par objet.** C'est le seul contrôle
   qui protège réellement contre la dérive du chart, et il échoue à la moindre
   divergence autre que `managed-by`.

C'est pour le troisième point que le job tourne sur `alpine/k8s` et non sur une
image Helm seule : il lui faut `kubectl` dans le même conteneur pour construire
le rendu de référence. `alpine/helm` n'embarque pas `kubectl` (vérifié).

## 7. Les limites assumées

**Le chart n'a jamais déployé.** Il est rendu, linté, comparé, et accepté par le
serveur d'API en `--dry-run=server`. Rien de plus. Un `helm install` réel n'a été
joué qu'une fois, dans un namespace jetable, pour observer les métadonnées du
§2 — et il s'est arrêté sur l'Ingress (voir ci-dessous).

**L'Ingress entre en collision avec l'environnement déjà déployé.** Sur ce
cluster, `microcrm-staging` porte un Ingress sur `microcrm.staging.example.com`.
Le webhook d'admission d'ingress-nginx refuse tout second Ingress sur le même
hôte, quel que soit son namespace :

```
admission webhook "validate.nginx.ingress.kubernetes.io" denied the request:
host "microcrm.staging.example.com" and path "/" is already defined in
ingress microcrm-staging/microcrm
```

Ce n'est pas un défaut du chart — le rendu Kustomize est refusé de la même façon
—, mais il faut le savoir pour ne pas chercher l'erreur au mauvais endroit. Un
essai dans un namespace neuf doit donc utiliser d'autres hôtes.

**Rien n'exécute `helm upgrade` dans le pipeline**, et c'est cohérent avec le
§3. Ajouter un job de déploiement Helm demanderait de trancher lequel des deux
mécanismes possède chaque environnement — et le §3 montre qu'ils ne peuvent pas
se partager le même.

## 8. Rejouer

```shell
# Rendu, sans cluster ni registry
helm template microcrm helm/microcrm -f helm/microcrm/values-staging.yaml

# Lint, sur les deux jeux de valeurs
helm lint helm/microcrm -f helm/microcrm/values-staging.yaml
helm lint helm/microcrm -f helm/microcrm/values-production.yaml

# Validation par le serveur d'API. Le `-n` n'est pas facultatif : sans lui le
# dry-run vise `default`, et le webhook d'ingress-nginx le refuse pour collision
# d'hôte avec l'Ingress réellement déployé (§7).
helm template microcrm helm/microcrm -f helm/microcrm/values-staging.yaml \
  | kubectl apply --dry-run=server -n microcrm-staging -f -

# Équivalence avec Kustomize — c'est le contrôle qui compte
sh scripts/tests/validate_k8s.sh --autotest
```

Déployer réellement, si l'on décidait un jour de basculer sur Helm (voir §3
avant) :

```shell
helm upgrade --install microcrm helm/microcrm \
  -f helm/microcrm/values-staging.yaml \
  -n "$STAGING_NAMESPACE" \
  --set image.repository="$CI_REGISTRY_IMAGE" \
  --set image.tag="$CI_COMMIT_SHORT_SHA"
```

Les deux `--set` sont l'équivalent exact de l'overlay éphémère que les jobs de
déploiement composent pour Kustomize ([K8S.md](K8S.md) §6).
