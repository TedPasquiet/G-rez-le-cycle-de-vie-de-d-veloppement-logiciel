variable "namespace" {
  description = "Namespace où poser les policies. Sans défaut : une valeur de repli ferait porter le cloisonnement au mauvais environnement en cas d'oubli, et l'erreur serait muette."
  type        = string
}

variable "labels" {
  description = "Labels d'identité posés sur les policies. L'appelant passe ceux du namespace, pour que les deux modules soient recensés par la même requête."
  type        = map(string)
  # Défaut vide plutôt qu'obligatoire : le module reste utilisable seul, et un
  # appelant qui oublie ce paramètre obtient des policies fonctionnelles — pas
  # d'échec, seulement une perte de traçabilité.
  default = {}
}

variable "enabled" {
  description = "Interrupteur global du module. À false, aucune policy n'est créée."
  type        = bool
  # Défaut à true parce que le cloisonnement est l'état attendu : c'est le fait
  # de l'ouvrir qui doit être une décision écrite dans un environnement, pas
  # l'inverse. L'interrupteur existe pour qu'un environnement dont le CNI
  # n'applique rien puisse se passer d'objets inertes sans supprimer le code —
  # et pour couper le cloisonnement en incident sans toucher au module.
  default = true
}

variable "ingress_controller_namespace" {
  description = "Namespace du contrôleur d'Ingress, seule source de trafic entrant autorisée."
  type        = string
  # ingress-nginx est le namespace créé par l'addon minikube. Variabilisé parce
  # qu'une installation par Helm le place couramment ailleurs, et qu'une valeur
  # fausse ici ne casse rien de visible : les policies s'appliquent, le trafic
  # tombe, et le symptôme est un 502 du contrôleur — pas une erreur Terraform.
  default = "ingress-nginx"
}

variable "back_port" {
  description = "Port d'écoute du conteneur back."
  type        = number
  default     = 8080
}

variable "front_port" {
  description = "Port d'écoute du conteneur front."
  type        = number
  # 80 tient à une capability de fichier (`cap_net_bind_service=ep`) portée par
  # le binaire Caddy, pas à un privilège du conteneur. Le Caddyfile accepte
  # `{$SITE_PORT:80}` : si un environnement s'en sert, cette variable doit
  # suivre, sinon la policy filtre un port que plus personne n'écoute.
  default = 80
}
