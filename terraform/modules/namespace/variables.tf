variable "name" {
  description = "Nom du namespace Kubernetes à créer."
  type        = string
}

variable "environment" {
  description = "Environnement porté par ce namespace (\"staging\" ou \"production\")."
  type        = string

  # Sans cette validation, une faute de frappe (« prod », « Production ») passerait
  # sans bruit : elle n'atterrirait que dans un label, donc aucune ressource
  # n'échouerait. On s'en apercevrait des mois plus tard, quand un
  # `kubectl get ns -l app.kubernetes.io/environment=production` reviendrait
  # vide. Échouer au plan coûte quelques secondes, l'autre chemin coûte une
  # enquête.
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment doit valoir \"staging\" ou \"production\"."
  }
}

variable "extra_labels" {
  description = "Labels supplémentaires appliqués au namespace, fusionnés avec les labels d'identité du module."
  type        = map(string)
  default     = {}
}

variable "quota" {
  description = "Plafonds du ResourceQuota du namespace. Quantités Kubernetes sous forme de chaînes (\"2\", \"500m\", \"2Gi\")."

  # Tous les attributs sont des chaînes, y compris `pods` qui est pourtant un
  # entier : les quantités Kubernetes ne sont pas des nombres au sens HCL. Écrire
  # `cpu = 0.5` produirait « 0.5 » là où le cluster attend « 500m », et un nombre
  # comme 1e3 serait rendu en notation scientifique, refusée par l'API. En
  # imposant la chaîne partout, la valeur écrite dans le tfvars est exactement
  # celle que reçoit le cluster.
  type = object({
    pods            = string
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
  })
}

variable "container_limits" {
  description = "LimitRange appliqué aux conteneurs du namespace : valeurs par défaut injectées et plafond par conteneur."

  type = object({
    # Servent aux conteneurs qui ne déclarent PAS leurs ressources. Les
    # manifestes Kustomize de MicroCRM les déclarent tous, donc ces défauts ne
    # s'appliquent en pratique qu'aux pods ajoutés à la main (débogage,
    # `kubectl run`) — précisément ceux qui, sans request, consommeraient du
    # quota de façon imprévisible ou seraient rejetés par le ResourceQuota.
    default_request_cpu    = string
    default_request_memory = string
    default_limit_cpu      = string
    default_limit_memory   = string
    max_cpu                = string
    max_memory             = string
  })
}
