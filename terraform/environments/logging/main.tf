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
#
# Une seule exception, et elle ne contredit pas ce qui précède : la policy
# ci-dessous ne sélectionne QUE les pods d'APM Server. Le modèle NetworkPolicy
# ne touche que les pods qu'une policy sélectionne — Elasticsearch, Kibana et
# Filebeat restent donc exactement dans l'état d'avant, sans règle.

# Seul point d'entrée de la stack ouvert à un AUTRE namespace : les pods `back`
# de staging et de production y envoient leurs traces OpenTelemetry. C'est
# aussi le seul composant qui ACCEPTE des écritures de l'extérieur sans aucune
# authentification (k8s/elk/apm-server-config.yaml) — n'importe quel pod du
# cluster, y compris ceux des projets voisins, pourrait sinon y verser des
# traces qui finiraient dans l'Elasticsearch de MicroCRM.
#
# Ce que cette policy ouvre, et rien d'autre :
#   source      les namespaces de var.apm_client_namespaces, tous pods ;
#   port        8200/TCP, le port du CONTENEUR (voir le module network-policy
#               pour la raison : la policy voit le paquet après traduction par
#               kube-proxy).
#
# Pas de `pod_selector` sur la source (« seulement les pods back ») : les pods
# du namespace applicatif portent des labels posés par Kustomize ou Helm, et
# restreindre à `app.kubernetes.io/name=back` couperait les traces d'un futur
# composant instrumenté sans le moindre signal. La granularité du namespace est
# celle de toutes les autres policies du projet.
#
# Côté émetteur, RIEN à ouvrir : les policies des namespaces applicatifs
# (modules/network-policy) ne restreignent que l'Ingress, l'egress y est libre.
#
# ⚠️ Mêmes réserves que le module network-policy, qu'il est inutile de répéter
# en entier : inerte sur le CNI par défaut de minikube, et hypothèse non
# vérifiée sur les sondes du kubelet (issues du nœud, qu'aucune règle
# n'autorise). Le `kubectl port-forward` de diagnostic passe, lui, par le
# kubelet et non par le réseau des pods : il n'est pas concerné.
resource "kubernetes_network_policy_v1" "allow_apps_to_apm_server" {
  metadata {
    name      = "allow-microcrm-to-apm-server"
    namespace = module.namespace.name
    # Mêmes labels que le namespace, pour répondre au même recensement
    # (`-l app.kubernetes.io/managed-by=terraform`) — voir modules/namespace.
    labels = module.namespace.labels
  }

  spec {
    pod_selector {
      # Label du `spec.selector.matchLabels` du Deployment : immuable après
      # création, donc la policy et le Deployment ne peuvent pas diverger sans
      # qu'on recrée l'un des deux.
      match_labels = {
        "app.kubernetes.io/name" = "apm-server"
      }
    }

    ingress {
      from {
        # `In` sur le label posé par l'API server : une seule règle pour N
        # namespaces, et aucun étiquetage manuel des namespaces applicatifs.
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = var.apm_client_namespaces
          }
        }
      }

      ports {
        port     = var.apm_server_port
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}
