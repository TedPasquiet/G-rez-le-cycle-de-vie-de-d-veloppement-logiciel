# Environnement de production.
#
# Rigoureusement la même composition qu'en staging, aux valeurs près. Si ces
# deux fichiers venaient à diverger dans leur structure, la production cesserait
# d'être validée par le staging — c'est le seul intérêt d'avoir deux
# environnements.

module "namespace" {
  source = "../../modules/namespace"

  name        = var.namespace
  environment = "production"

  quota            = var.quota
  container_limits = var.container_limits
}

module "network_policy" {
  source = "../../modules/network-policy"

  namespace = module.namespace.name
  enabled   = var.network_policy_enabled

  labels                       = module.namespace.labels
  ingress_controller_namespace = var.ingress_controller_namespace
}
