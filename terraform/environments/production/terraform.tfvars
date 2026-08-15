# Dimensionnement de l'environnement de production.
#
# Ce fichier est la seule chose qui distingue la production du staging. Toute
# différence de comportement entre les deux environnements doit pouvoir se lire
# ici ; si elle n'y est pas, c'est qu'elle s'est glissée ailleurs, et c'est un
# défaut.

namespace = "microcrm-production"

# ---------------------------------------------------------------------------
# ResourceQuota
# ---------------------------------------------------------------------------
# Même méthode qu'en staging — dimensionner sur le PIC d'un déploiement
# (`maxSurge: 1, maxUnavailable: 0`), jamais sur l'état stable. Deux écarts
# avec staging : le back porte le patch de production (requests 500m / 768Mi,
# limits 2 CPU / 1Gi) et le front tourne à 2 replicas.
#
# Pic en production (back 1→2 pods, front 2→3 pods) :
#
#   requests   back  2 × (500m / 768Mi) = 1000m / 1536Mi
#              front 3 × ( 10m /  32Mi) =   30m /   96Mi
#              --------------------------------------------
#              total                      1030m / 1632Mi
#
#   limits     back  2 × (2000m / 1024Mi) = 4000m / 2048Mi
#              front 3 × ( 200m /   64Mi) =  600m /  192Mi
#              ----------------------------------------------
#              total                        4600m / 2240Mi
#
# ⚠️ Le back reste à 1 replica en régime stable, et le pic est donc à 2. Le
# jour où la base sortira de la mémoire du processus (K8S.md §8.1) et où le
# back passera à plusieurs replicas, ces plafonds seront à recalculer — sans
# quoi le premier déploiement après le changement échouera sur `exceeded
# quota`, et la cause sera cherchée partout sauf ici.
quota = {
  pods            = "20"
  requests_cpu    = "2"
  requests_memory = "2Gi"
  limits_cpu      = "6"
  limits_memory   = "3Gi"
}

# ---------------------------------------------------------------------------
# LimitRange
# ---------------------------------------------------------------------------
# Valeurs identiques à celles de staging. C'est volontaire : si la production
# tolérait des conteneurs que staging refuse, staging cesserait de valider quoi
# que ce soit. `max_memory` vaut exactement le `limits.memory` du back de
# production (1Gi) — le plafond est atteint, pas dépassé, et un pod dont les
# limites égalent le `max` est accepté.
container_limits = {
  default_request_cpu    = "50m"
  default_request_memory = "64Mi"
  default_limit_cpu      = "500m"
  default_limit_memory   = "256Mi"
  max_cpu                = "2"
  max_memory             = "1Gi"
}
