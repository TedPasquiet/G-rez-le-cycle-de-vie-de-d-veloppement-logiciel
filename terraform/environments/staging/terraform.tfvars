# Dimensionnement de l'environnement de staging.
#
# Fichier VERSIONNÉ : aucune donnée sensible ici, uniquement des plafonds. Ce
# sont ces valeurs, et elles seules, qui distinguent staging de production.

namespace = "microcrm-staging"

# ---------------------------------------------------------------------------
# ResourceQuota
# ---------------------------------------------------------------------------
# Le calcul se fait sur le PIC d'un déploiement, pas sur l'état stable. Les
# deux Deployments sont en `maxSurge: 1, maxUnavailable: 0` : le nouveau pod
# doit être prêt AVANT que l'ancien ne parte, donc il existe un instant où les
# deux coexistent. Un quota calé sur l'état stable laisserait tourner
# l'application et bloquerait chaque mise à jour, sur un `exceeded quota` qui
# ne dit pas qu'il s'agit d'un problème de dimensionnement.
#
# Pic en staging (back 1→2 pods, front 1→2 pods) :
#
#   requests   back 2 × (200m / 512Mi) = 400m / 1024Mi
#              front 2 × ( 10m /  32Mi) =  20m /   64Mi
#              -------------------------------------------
#              total                     420m / 1088Mi
#
#   limits     back 2 × (1000m / 768Mi) = 2000m / 1536Mi
#              front 2 × ( 200m /  64Mi) =  400m /  128Mi
#              --------------------------------------------
#              total                      2400m / 1664Mi
#
# Les plafonds ci-dessous couvrent ce pic avec de la marge — assez pour un pod
# ponctuel (un `kubectl debug`, un Job), pas assez pour qu'une boucle de
# création passe inaperçue.
quota = {
  pods            = "10"
  requests_cpu    = "1"
  requests_memory = "1536Mi"
  limits_cpu      = "3"
  limits_memory   = "2Gi"
}

# ---------------------------------------------------------------------------
# LimitRange
# ---------------------------------------------------------------------------
# Le quota ci-dessus rend les requests obligatoires : un pod qui n'en déclare
# pas est REJETÉ dès lors qu'un `requests.cpu` figure au quota. Les deux
# Deployments de MicroCRM en déclarent, mais pas forcément le pod de dépannage
# lancé à la main un jour de panne. Ces défauts lui en donnent, plutôt que de
# le laisser échouer.
#
# `max` doit rester supérieur ou égal au plus gros `limits` déclaré par un
# conteneur, sinon le pod est refusé. Le plus gros ici est le back de
# production (2 CPU / 1Gi) : on garde la même valeur dans les deux
# environnements pour que staging ne puisse pas accepter un manifeste que la
# production refuserait.
container_limits = {
  default_request_cpu    = "50m"
  default_request_memory = "64Mi"
  default_limit_cpu      = "500m"
  default_limit_memory   = "256Mi"
  max_cpu                = "2"
  max_memory             = "1Gi"
}
