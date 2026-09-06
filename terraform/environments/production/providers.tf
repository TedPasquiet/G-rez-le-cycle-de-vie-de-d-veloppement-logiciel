# Configuration du provider Kubernetes pour la production.
# Voir terraform/environments/staging/providers.tf pour les justifications.

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context

  ignore_labels = [
    "kubernetes.io/metadata.name",
  ]
}
