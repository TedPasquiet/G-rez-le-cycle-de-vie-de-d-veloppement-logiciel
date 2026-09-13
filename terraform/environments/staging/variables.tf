# Variables de l'environnement de staging.
#
# Les valeurs sont dans terraform.tfvars, qui est VERSIONNÉ : il ne contient
# que du dimensionnement, aucune donnée sensible, et c'est ce qui permet de
# recréer l'environnement depuis le seul dépôt.

variable "namespace" {
  description = <<-EOT
    Namespace de staging.

    ⚠️ Cette valeur doit être identique à $STAGING_NAMESPACE dans les variables
    du projet GitLab. Rien ne le vérifie automatiquement : Terraform crée le
    namespace, la CI y déploie l'application, et les deux ne se parlent pas. En
    cas de divergence, le job deploy-staging échouerait sur un namespace
    inexistant — ou pire, en créerait un second, sans quota.
  EOT
  type        = string
}

variable "kubeconfig_path" {
  description = <<-EOT
    Chemin du kubeconfig. Laisser le défaut sur un poste de développement.

    En CI, ce défaut ne peut PAS convenir : l'image d'outillage tourne en root,
    `~` s'y résout en `/root`, et aucun kubeconfig n'existe à cet endroit —
    `plan` échoue alors sur « 'config_path' refers to an invalid path » avant
    même de planifier. Les jobs exportent donc `TF_VAR_kubeconfig_path` vers le
    kubeconfig que l'agent GitLab pour Kubernetes fabrique pour le job
    ($KUBECONFIG). Voir TERRAFORM.md §4.1.
  EOT
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = <<-EOT
    Contexte kubectl visé. `minikube` en local (décision D2 : tout en local).

    C'est le garde-fou le plus utile de ce fichier : sans contexte explicite,
    Terraform applique sur le contexte courant, c'est-à-dire sur ce que le
    dernier `kubectl config use-context` a laissé. Nommer la cible fait échouer
    l'exécution plutôt que de la laisser toucher le mauvais cluster.

    En CI, le contexte n'est pas `minikube` : l'agent GitLab en fabrique un,
    nommé `<chemin du projet>:<nom de l'agent>`. Les jobs le composent dans
    `TF_VAR_kube_context` à partir de $CI_PROJECT_PATH et $KUBE_AGENT_NAME.
  EOT
  type        = string
  default     = "minikube"
}

variable "quota" {
  description = "Plafonds du ResourceQuota. Voir terraform.tfvars pour le calcul."
  type = object({
    pods            = string
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
  })
}

variable "container_limits" {
  description = "Valeurs par défaut et plafond par conteneur (LimitRange)."
  type = object({
    default_request_cpu    = string
    default_request_memory = string
    default_limit_cpu      = string
    default_limit_memory   = string
    max_cpu                = string
    max_memory             = string
  })
}

variable "ingress_controller_namespace" {
  description = <<-EOT
    Namespace du contrôleur d'Ingress, seule source de trafic entrant autorisée
    par les NetworkPolicy.

    Exposé ici, et pas seulement dans le module, parce que c'est une propriété
    du CLUSTER et non de l'application : `ingress-nginx` avec l'addon minikube,
    couramment ailleurs avec une installation par Helm. Une valeur fausse ne
    produit aucune erreur Terraform — les policies s'appliquent, le trafic
    tombe, et le symptôme est un 502 du contrôleur.
  EOT
  type        = string
  default     = "ingress-nginx"
}

variable "network_policy_enabled" {
  description = <<-EOT
    Pose les NetworkPolicy dans le namespace.

    Laissé à `true` y compris sur minikube, où le CNI par défaut ne les applique
    PAS : l'état désiré est le même partout, et c'est le cluster qui décide de
    l'appliquer ou non. Voir TERRAFORM.md §6.2 et §9.3.
  EOT
  type        = bool
  default     = true
}
