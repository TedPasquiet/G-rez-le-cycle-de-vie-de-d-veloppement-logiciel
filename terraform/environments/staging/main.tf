# Environnement de staging.
#
# Ce fichier n'écrit aucune ressource : il compose des modules. C'est ce qui
# garantit que staging et production ne peuvent pas diverger autrement que par
# leurs valeurs — la forme, elle, est écrite une seule fois dans
# terraform/modules/.

module "namespace" {
  source = "../../modules/namespace"

  name        = var.namespace
  environment = "staging"

  quota            = var.quota
  container_limits = var.container_limits
}

module "network_policy" {
  source = "../../modules/network-policy"

  # Le namespace vient de la SORTIE du module, pas de la variable. La
  # différence n'est pas cosmétique : elle crée la dépendance qui fait attendre
  # Terraform. Avec `var.namespace`, les policies pourraient partir avant que
  # le namespace n'existe, et l'exécution échouerait une fois sur deux selon
  # l'ordre choisi par le graphe.
  namespace = module.namespace.name
  enabled   = var.network_policy_enabled

  # Les policies portent les mêmes labels que le namespace : sans cela, elles
  # échapperaient au recensement `-l app.kubernetes.io/managed-by=terraform`
  # (TERRAFORM.md §3), et un inventaire incomplet est pire qu'aucun.
  labels = module.namespace.labels

  ingress_controller_namespace = var.ingress_controller_namespace
}
