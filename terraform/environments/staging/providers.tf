# Configuration du provider Kubernetes.
#
# Elle est ici, dans l'environnement, et pas dans les modules : un module qui
# déclare son propre `provider` ne peut plus être réutilisé contre un autre
# cluster, et Terraform interdit de le supprimer proprement ensuite. Les
# modules héritent donc de ce bloc.

provider "kubernetes" {
  # Aucune coordonnée de cluster n'est écrite dans le dépôt — même règle que
  # pour les manifestes Kustomize (K8S.md §4). On désigne un kubeconfig et un
  # contexte, tous deux surchargeables par variable.
  config_path    = var.kubeconfig_path
  config_context = var.kube_context

  # `kubernetes.io/metadata.name` est posé par le serveur d'API sur TOUT
  # namespace, sans que personne ne le demande. Sans cette ligne, Terraform le
  # voit comme une dérive et propose de le retirer à chaque plan — une
  # modification qui, elle, serait aussitôt réécrite par le serveur. Boucle
  # sans fin et plan jamais vide.
  ignore_labels = [
    "kubernetes.io/metadata.name",
  ]
}
