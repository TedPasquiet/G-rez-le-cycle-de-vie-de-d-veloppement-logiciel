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
  description = <<-EOT
    Chemin du kubeconfig. Le défaut ne vaut que pour un poste ; en CI, les jobs
    exportent `TF_VAR_kubeconfig_path` vers le kubeconfig de l'agent GitLab.
    Justifications dans terraform/environments/staging/variables.tf.
  EOT
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

variable "apm_client_namespaces" {
  description = <<-EOT
    Namespaces autorisés à envoyer des traces à APM Server (port 8200). Ce sont
    ceux des environnements applicatifs, dont les pods `back` portent l'agent
    OpenTelemetry.
  EOT
  type        = list(string)
  # Sans défaut, comme `namespace` : une valeur de repli ouvrirait APM Server au
  # mauvais environnement en cas d'oubli, et l'erreur serait muette.
  #
  # ⚠️ Liste vide = policy qui sélectionne APM Server sans aucune source
  # autorisée, donc un refus TOTAL dès qu'un CNI l'applique. La validation
  # l'interdit plutôt que de laisser les traces se perdre en silence.
  validation {
    condition     = length(var.apm_client_namespaces) > 0
    error_message = "apm_client_namespaces doit contenir au moins un namespace, sinon APM Server ne reçoit plus rien."
  }
}

variable "apm_server_port" {
  description = "Port d'écoute du CONTENEUR APM Server (OTLP/HTTP, OTLP/gRPC et intake natif, multiplexés)."
  type        = number
  # 8200 : celui de k8s/elk/apm-server-deployment.yaml. Une valeur fausse ici
  # ne casse rien de visible au `plan` ; sur un CNI qui applique la policy, les
  # traces tombent et l'agent Java n'en dit qu'une ligne par minute.
  default = 8200
}
