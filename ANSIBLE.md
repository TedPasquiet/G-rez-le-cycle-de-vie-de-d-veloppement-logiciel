# Ansible — le poste et le cluster

Ansible prépare ce qui existe **avant** que Terraform ou Kustomize n'aient
quelque chose à quoi parler : l'outillage du poste et le cluster minikube.

**État : les deux rôles tournent, sont idempotents et passent `ansible-lint`.**
Ansible agit sur le poste lui-même : tout ce qu'il promet se vérifie sur cette
machine.

| Vérification                                    | Résultat                                           |
| ----------------------------------------------- | -------------------------------------------------- |
| `ansible-lint` sur tout `ansible/`              | `0 failure(s), 0 warning(s)` — profil `production` |
| 1re exécution de `site.yml`                     | `ok=23 changed=0 failed=0`                         |
| 2e exécution consécutive                        | `ok=23 changed=0 failed=0`                         |
| `site.yml --check`                              | `ok=23 changed=0 failed=0`                         |
| Reconstruction de staging (2026-09-22), étape 1 | `ok=23 changed=0 failed=0` (`RELEASE.md` §9.5)     |
| Job `ansible-lint` de la CI                     | à chaque pipeline (§9)                             |

## 1. Le problème que ça résout

Déployer sur un cluster vierge suppose un cluster, un contrôleur d'Ingress, un
contexte `minikube` courant, et des outils (`kubectl`, `helm`, `terraform`…) dans
des versions compatibles. Écrits comme prérequis dans une documentation, ces
points restent à la charge du lecteur, qui doit deviner comment y arriver et
quelles versions le projet attend.

Ansible les transforme en code exécutable et rejouable.

## 2. La frontière — quatre couches, aucun recouvrement

C'est la règle de `TERRAFORM.md` §3, prolongée d'un cran vers le bas.

| Couche                 | Propriétaire                   | Ce qu'il possède                                             |
| ---------------------- | ------------------------------ | ------------------------------------------------------------ |
| Le poste et le cluster | **Ansible**                    | l'outillage et ses versions ; le profil minikube, ses addons |
| Le namespace           | **Terraform**                  | `Namespace`, `ResourceQuota`, `LimitRange`, `NetworkPolicy`  |
| L'application          | **Kustomize** (Helm en double) | `Deployment`, `Service`, `Ingress`, `ConfigMap`              |
| Les secrets            | **la CI**                      | le `Secret` du registry                                      |

**Ansible s'arrête au bord du namespace et ne crée aucun objet Kubernetes.**
C'est la ligne à ne pas franchir : Ansible sait parfaitement appliquer un
manifeste (`kubernetes.core.k8s`), et c'est précisément pour cela qu'il faut
écrire qu'il ne le fera pas. Deux outils qui écrivent le même objet, c'est deux
sources de vérité, et un `terraform plan` qui propose sans fin de défaire ce que
le playbook vient de poser.

Enchaînement complet, depuis un poste nu :

```
1. ansible-playbook site.yml            le poste et le cluster
2. terraform apply                      le namespace et ses garde-fous
3. kubectl apply -k k8s/overlays/<env>  l'application (ou la CI)
```

## 3. Les deux rôles

**`outillage`** installe les formules Homebrew listées dans
`group_vars/all.yml`, puis vérifie que les versions obtenues atteignent le
minimum attendu. Sortie de la seconde exécution sur ce poste :

```
kubectl        1.36.2    minimum 1.30
helm           4.2.2     minimum 3.14
terraform      1.15.7    minimum 1.5
minikube       1.38.1    minimum 1.30
ansible-lint   26.8.0    minimum 24.0
docker         29.5.3    vérifié, jamais installé par ce rôle
```

**`cluster`** garantit que le profil minikube tourne avec ses addons :

```
Profil        : minikube (docker)
Statut        : hôte Running, API Running, kubelet Running
Kubernetes    : v1.35.1
Dimensionnem. : 2 CPU, 6100 Mio
Addons actifs : default-storageclass, ingress, registry, storage-provisioner
Contexte      : minikube
```

Le **contexte kubectl** figure au récapitulatif à dessein : c'est lui qui décide
de la cible réelle d'un `terraform apply` comme d'un `kubectl apply -k`, et
aucune de ces deux commandes ne le rappelle.

## 4. Versions minimales, et non exactes

`group_vars/all.yml` déclare une `version_minimale` par outil, jamais une
version exacte. Ce n'est pas un relâchement de la discipline du projet, c'est sa
seule application possible ici : **Homebrew installe toujours la dernière
version d'une formule** et ne sait pas revenir en arrière proprement. Exiger une
version exacte donnerait un rôle qui échoue le lendemain de la première mise à
jour du miroir, sans qu'aucun commit ne l'explique.

Les versions exactes sont figées là où elles comptent vraiment et où c'est
possible : les images d'outillage du `.gitlab-ci.yml`, qui sont ce que la CI
exécute réellement. Le poste, lui, doit seulement être **assez récent**.

Le champ `version_relevee` garde le relevé fait sur ce poste. Quand la version
mesurée en diverge, le récapitulatif le signale — sans jamais s'en servir pour
décider.

## 5. Ce qu'Ansible n'installe pas, et pourquoi

**Docker.** Docker Desktop est une application graphique, souvent installée à la
main et parfois par un canal d'entreprise. L'installer depuis un playbook
risquerait de doubler une installation existante. Le rôle vérifie sa présence et
échoue avec cette raison affichée, plutôt que d'agir à la place de quelqu'un.

**Ansible lui-même.** Un playbook ne peut pas installer l'interpréteur qui
l'exécute.

## 6. ⚠️ Le rôle `cluster` ne détruit jamais rien

C'est la décision la plus importante de la partie Ansible, et elle mérite d'être
défendue.

minikube ne sait pas redimensionner un profil existant : changer `--cpus` ou
`--memory` suppose un `minikube delete` suivi d'un `minikube start`, donc la
perte de tout ce que le cluster contient — ici le namespace `microcrm-staging`
et l'application qui y tourne.

Un rôle qui « convergerait » vers `cluster_cpus` / `cluster_memoire_mo` serait
donc un rôle destructeur, avec cette particularité perverse : **il ne détruirait
que sur les postes déjà en service**. Sur une machine neuve il créerait
simplement le cluster, et le défaut resterait invisible jusqu'au jour où
quelqu'un le joue sur une machine qui travaille.

Le rôle **signale** l'écart et continue. Ni `minikube delete`, ni `minikube
start` sur un profil déjà démarré n'apparaissent nulle part.

L'écart n'est signalé que si le relevé est **strictement inférieur** à la cible,
jamais s'il est supérieur : le dimensionnement est un plancher. Ce poste dispose
de 6100 Mio pour 4096 demandés, et n'affiche donc rien — un avertissement qui se
déclenche toujours cesse d'être lu.

## 7. La preuve d'idempotence

C'est le critère de validation de la tâche. Deux exécutions consécutives, sans
rien changer entre les deux :

```
$ cd ansible && ansible-playbook site.yml
poste : ok=23   changed=0    unreachable=0    failed=0    skipped=3

$ ansible-playbook site.yml
poste : ok=23   changed=0    unreachable=0    failed=0    skipped=3
```

Les **trois tâches sautées** sont exactement celles qui ne doivent rien faire sur
un poste déjà prêt : démarrer le profil, signaler un écart de dimensionnement,
activer les addons manquants. Une tâche sautée est ici le signe que le rôle sait
reconnaître un travail déjà fait.

L'idempotence ne va pas de soi, et trois règles la produisent :

1. **installer par module, jamais par `command: brew install …`.** Le module
   compare l'état réel avant d'agir ; le `command` ne compare rien et se déclare
   `changed` à chaque passage ;
2. **une tâche qui LIT porte `changed_when: false`.** Un `command` se croit
   modifiant par défaut, et son oubli est la cause la plus banale d'un rôle qui
   n'est idempotent qu'à moitié ;
3. **une tâche qui AGIT est conditionnée par l'état relevé juste avant.**
   `minikube addons enable` est réentrant, mais l'appeler sur un addon déjà
   actif signalerait `changed` éternellement : l'idempotence se joue dans le
   `difference`, pas dans la commande.

`assert` et `debug`, eux, ne signalent jamais `changed` — c'est ce qui les rend
utilisables pour tout ce qui vérifie et tout ce qui affiche.

## 8. Trois pièges, et ce qu'ils imposent au code

Ils sont documentés parce qu'ils se reproduisent sur tout projet Ansible.

**Un booléen qui passe par `vars:` devient une chaîne.** `false` y ressort en
« False », qui n'est pas vide, donc **vrai** pour `selectattr`. Le filtre
`| bool` corrige la valeur, mais ansible-core l'a déprécié pour cet usage
(« this feature will be removed from ansible-core 2.23 »). Le rôle `outillage`
évalue donc le test là où il est utilisé, où il produit un vrai booléen.

**`stdout_callback = yaml` fait échouer le playbook entier**, avant la première
tâche : ce greffon a été retiré de `community.general` en 12.0.0. `ansible.cfg`
emploie à la place l'option du greffon par défaut d'ansible-core,
`callback_result_format = yaml`. Le nom de clé compte : `result_format`, mal
nommé, est accepté sans message et purement ignoré.

**`ansible.cfg` n'est lu que si le répertoire courant est `ansible/`.** Un
`ansible-playbook ansible/site.yml` lancé depuis la racine du dépôt l'ignore en
silence et tourne sans inventaire. D'où le `cd ansible` dans toutes les commandes
de ce document, et le message d'échec du rôle `cluster` qui nomme cette cause.

## 9. Les limites assumées

**Un seul hôte, et c'est ce poste.** La décision D2 a retenu l'option locale :
il n'existe ni serveur distant ni compte cloud. `inventory/local.yml` est le seul
fichier à changer le jour où un hôte distant apparaîtrait ; les rôles ne
présument rien de la connexion.

**macOS et Homebrew uniquement.** Le rôle `outillage` ne saurait pas préparer un
poste Linux. Le rendre portable demanderait un chemin par gestionnaire de
paquets, pour un gain nul tant que le projet n'a qu'un poste.

**Le pipeline vérifie Ansible, il ne l'exécute pas.** Le job `ansible-lint`
(étape `infra`, image `$PYTHON_IMAGE` avec `ansible` 14.1.0 et `ansible-lint`
26.8.0 figés) lance `scripts/ci/ansible_check.sh` : `--syntax-check` du
playbook, puis `ansible-lint`, depuis `ansible/` pour que `ansible.cfg` soit
lu. Le playbook lui-même n'a pas vocation à tourner en CI : il prépare un poste
de développement, pas un exécuteur.

**La stack ELK n'est pas dans Ansible, et c'est conforme à la frontière.** Son
namespace `logging` est créé par Terraform, son contenu par
`kubectl apply -k k8s/elk` ([MONITORING.md](MONITORING.md)) : Ansible
s'arrête au cluster (§2).

## 10. Rejouer

```shell
cd ansible

# Installer les collections — inutile avec le paquet `ansible` complet,
# indispensable avec `ansible-core` seul (voir requirements.yml)
ansible-galaxy collection install -r requirements.yml

ansible-playbook site.yml              # le poste et le cluster
ansible-playbook site.yml --check      # diagnostic, sans rien modifier
ansible-playbook site.yml --tags outillage
ansible-playbook site.yml --tags cluster

ansible-lint                           # doit sortir en 0
```

Pour auditer un poste sans y toucher :

```shell
ansible-playbook site.yml -e outillage_installer=false
```
