# Variables du namespace de la stack ELK.
# Les justifications communes sont dans terraform/environments/staging/variables.tf.

variable "namespace" {
  description = <<-EOT
    Namespace de la stack de journalisation.

    Contrairement aux deux autres environnements, celui-ci n'a PAS d'équivalent
    dans les variables GitLab : aucun job ne déploie ELK. C'est une pièce de
    plateforme, montée à la main sur le cluster local, et sa seule couture est
    avec `kubectl apply -k k8s/elk -n <ce namespace>` (MONITORING.md).
  EOT
  type        = string
}

variable "kubeconfig_path" {
  description = "Chemin du kubeconfig."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Contexte kubectl visé. Voir l'équivalent en staging."
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
