# Dimensionnement du namespace de la stack ELK.

namespace = "logging"

# ---------------------------------------------------------------------------
# ResourceQuota
# ---------------------------------------------------------------------------
# Même méthode que pour les environnements applicatifs — dimensionner sur le
# PIC d'un déploiement, jamais sur l'état stable — mais le calcul du pic diffère
# ici, et c'est ce qui rend ce fichier intéressant : les trois composants n'ont
# pas la même stratégie de déploiement.
#
#   Elasticsearch  strategy: Recreate. Le PVC est ReadWriteOnce et le
#                  répertoire de données est verrouillé par node.lock : un
#                  second pod ne pourrait pas démarrer. Le pic vaut donc
#                  1 pod, pas 2.
#   Kibana         RollingUpdate, maxSurge 1 : pic à 2 pods.
#   Filebeat       DaemonSet sur un nœud unique : 1 pod, et un DaemonSet
#                  remplace ses pods sans en ajouter.
#
#   requests   elasticsearch 1 × (500m / 1536Mi) =  500m / 1536Mi
#              kibana        2 × (200m /  768Mi) =  400m / 1536Mi
#              filebeat      1 × (100m /  128Mi) =  100m /  128Mi
#              ----------------------------------------------------
#              total                              1000m / 3200Mi
#
#   limits     elasticsearch 1 × (2000m / 2048Mi) = 2000m / 2048Mi
#              kibana        2 × (1000m / 1536Mi) = 2000m / 3072Mi
#              filebeat      1 × ( 500m /  256Mi) =  500m /  256Mi
#              -----------------------------------------------------
#              total                                4500m / 5376Mi
#
# ⚠️ Le plafond mémoire reste SOUS l'allocatable du nœud (7,75 Gio), et il le
# faut : ce cluster n'est pas dédié à MicroCRM — il héberge aussi les
# namespaces `dev`, `staging` et quatre pods dans `default`. Un quota calé sur
# la capacité totale autoriserait ELK à évincer les projets voisins.
quota = {
  pods            = "12"
  requests_cpu    = "2"
  requests_memory = "4Gi"
  limits_cpu      = "6"
  limits_memory   = "6Gi"
}

# ---------------------------------------------------------------------------
# LimitRange
# ---------------------------------------------------------------------------
# `max_memory` vaut 2Gi et non 1Gi comme dans les environnements applicatifs :
# c'est exactement la limite d'Elasticsearch, qui est le plus gros conteneur du
# projet. Descendre sous cette valeur ferait REJETER son pod à l'admission, et
# l'erreur remonterait sur le ReplicaSet — pas sur le Deployment, qu'un
# `kubectl get deploy` montrerait simplement figé.
container_limits = {
  default_request_cpu    = "50m"
  default_request_memory = "64Mi"
  default_limit_cpu      = "500m"
  default_limit_memory   = "256Mi"
  max_cpu                = "2"
  max_memory             = "2Gi"
}
