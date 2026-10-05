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
#   APM Server     RollingUpdate, maxSurge 1 : pic à 2 pods. Ajouté avec le
#                  tracing OpenTelemetry (k8s/elk/apm-server-deployment.yaml).
#
#   requests   elasticsearch 1 × (500m / 1536Mi) =  500m / 1536Mi
#              kibana        2 × (200m /  768Mi) =  400m / 1536Mi
#              filebeat      1 × (100m /  128Mi) =  100m /  128Mi
#              apm-server    2 × ( 50m /   64Mi) =  100m /  128Mi
#              ----------------------------------------------------
#              total                              1100m / 3328Mi
#
#   limits     elasticsearch 1 × (2000m / 2048Mi) = 2000m / 2048Mi
#              kibana        2 × (1000m / 1536Mi) = 2000m / 3072Mi
#              filebeat      1 × ( 500m /  256Mi) =  500m /  256Mi
#              apm-server    2 × ( 500m /  256Mi) = 1000m /  512Mi
#              -----------------------------------------------------
#              total                                5500m / 5888Mi
#
# ⚠️ APM Server est entré SANS relever le quota, et la marge restante est
# désormais mince : 256Mi et 500m sur les limites. Le pic a été observé en
# conditions réelles le 2026-09-29, Kibana et APM Server en rollout simultané
# (APM Server alors à 100m / 128Mi de requests, abaissés depuis sur mesure) :
#
#   pods 6/12   limits.cpu 5500m/6   limits.memory 5888Mi/6Gi
#
# Le prochain composant ajouté à ce namespace — ou une hausse de la limite
# d'un existant — devra donc relever `limits_memory` ici, faute de quoi son
# rollout restera bloqué par l'admission (`exceeded quota`) sans que rien ne
# plante. Relever le quota pour APM Server seul aurait été du confort : il
# tient dedans, mesure à l'appui.
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

# ---------------------------------------------------------------------------
# Tracing — sources autorisées vers APM Server
# ---------------------------------------------------------------------------
# Les deux namespaces applicatifs, écrits en clair : ce sont ceux des
# terraform.tfvars de staging et de production (`namespace`). Les dériver de
# leur état Terraform (terraform_remote_state) couplerait trois états pour deux
# chaînes de caractères — et un changement de nom de namespace est de toute
# façon un geste qui se relit en revue, pas un détail qui dérive.
apm_client_namespaces = ["microcrm-staging", "microcrm-production"]
