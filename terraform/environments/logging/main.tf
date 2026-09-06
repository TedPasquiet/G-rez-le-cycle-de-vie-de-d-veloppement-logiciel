# Namespace de la stack ELK.
#
# Il est décrit ici, et pas dans k8s/elk/, parce que la frontière du projet ne
# souffre pas d'exception : Terraform possède les namespaces, Kustomize possède
# ce qu'il y a dedans (TERRAFORM.md §3). Un `Namespace` glissé dans les
# manifestes ELK aurait recréé, pour un seul objet, la double source de vérité
# que tout le lot Terraform sert à éviter.

module "namespace" {
  source = "../../modules/namespace"

  name = var.namespace
  # ⚠️ « logging » n'est pas un environnement au sens des deux autres : c'est un
  # namespace de plateforme, qui porte un composant partagé et non une version
  # de l'application. Cette valeur a dû être AJOUTÉE au vocabulaire fermé du
  # module (terraform/modules/namespace/variables.tf) : à la première
  # réutilisation réelle hors des deux environnements jumeaux, le module a
  # échoué au plan. Ce qui a prouvé deux choses d'un coup — que sa validation
  # sert à quelque chose, et que « réutilisable » ne se décrète pas.
  environment = "logging"

  quota            = var.quota
  container_limits = var.container_limits
}

# Pas de module network-policy ici, et c'est un choix, pas un oubli.
#
# Ses règles sont écrites pour l'application : un `default-deny` sur tout le
# namespace, puis deux autorisations nommant les pods `back` et `front` depuis
# le contrôleur d'Ingress. Appliquées ici, elles fermeraient le namespace sans
# rouvrir aucun des flux dont ELK a besoin — Filebeat vers Elasticsearch, Kibana
# vers Elasticsearch — et les deux autorisations viseraient des pods qui
# n'existent pas.
#
# Le cloisonnement de ce namespace demande donc ses propres règles, écrites
# contre la topologie d'ELK. Tant qu'elles ne sont pas écrites, mieux vaut
# aucune policy qu'un jeu de règles qui donne l'illusion d'en avoir.
