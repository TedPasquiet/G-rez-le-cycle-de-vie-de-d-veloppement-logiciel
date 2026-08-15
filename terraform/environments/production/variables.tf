# Variables de l'environnement de production.
# Les justifications communes sont dans terraform/environments/staging/variables.tf.

variable "namespace" {
  description = <<-EOT
    Namespace de production.

    ⚠️ Cette valeur doit être identique à $PROD_NAMESPACE dans les variables du
    projet GitLab, qui est une variable *protégée*. Rien ne vérifie la
    correspondance : Terraform crée le namespace, la CI y déploie. Une
    divergence se voit au premier deploy-production, au pire moment.
  EOT
  type        = string
}

variable "kubeconfig_path" {
  description = "Chemin du kubeconfig."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = <<-EOT
    Contexte kubectl visé.

    Le défaut est `minikube`, et c'est une limite assumée, pas un oubli : la
    décision D2 a retenu l'option locale, il n'existe donc aucun cluster de
    production. Ce que cet environnement démontre, c'est qu'un second
    environnement se décrit par les mêmes modules et des valeurs différentes —
    pas qu'une production existe.

    Le jour où un vrai cluster apparaît, rien ne change ici : on passe
    `-var kube_context=<contexte>`, ou la CI fournit $KUBE_CONFIG. Voir
    TERRAFORM.md §9.1.
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
  description = "Namespace du contrôleur d'Ingress. Voir l'équivalent en staging."
  type        = string
  default     = "ingress-nginx"
}

variable "network_policy_enabled" {
  description = "Pose les NetworkPolicy. Voir l'équivalent en staging."
  type        = bool
  default     = true
}
