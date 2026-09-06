# Ce module possède le *contenant* d'un environnement MicroCRM : le namespace et
# les garde-fous de consommation qui s'y appliquent. Il ne décrit aucune
# ressource applicative — Deployments, Services, Ingress et ConfigMap restent la
# propriété de Kustomize, et le Secret du registry celle de la CI (Terraform
# écrirait son mot de passe en clair dans l'état).
#
# La frontière n'est pas cosmétique : deux outils qui écrivent le même objet
# produisent deux sources de vérité, donc un `terraform plan` qui propose sans
# fin d'annuler ce que le dernier `kubectl apply` a posé. Elle est rendue
# lisible dans le cluster par le label `managed-by` ci-dessous.

locals {
  # `managed-by = terraform` s'oppose ici au `managed-by = kustomize` que la base
  # Kustomize appose sur toutes les ressources applicatives. La question
  # « qu'est-ce que je casse si je fais un destroy ? » se répond donc sans
  # ouvrir l'état — à condition d'énumérer les types, car `kubectl get all` ne
  # couvre AUCUN des objets de ce lot (ni Namespace, ni ResourceQuota, ni
  # LimitRange, ni NetworkPolicy ; `all` ne désigne qu'une poignée de types
  # applicatifs) :
  #
  #   kubectl get ns,resourcequota,limitrange,networkpolicy -A \
  #     -l app.kubernetes.io/managed-by=terraform
  #
  # Ces mêmes labels sont passés au module network-policy par l'appelant, sans
  # quoi les policies manqueraient à ce recensement.
  #
  # extra_labels passe en second dans le merge : l'appelant peut surcharger un
  # label d'identité. C'est assumé — le module n'a pas à interdire à un
  # environnement de se déclarer autrement.
  labels = merge(
    {
      "app.kubernetes.io/part-of"     = "microcrm"
      "app.kubernetes.io/managed-by"  = "terraform"
      "app.kubernetes.io/environment" = var.environment
    },
    var.extra_labels,
  )
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.name
    labels = local.labels
  }
}

# Plafond global de l'environnement. Sa raison d'être est de contenir un
# incident (fuite mémoire, boucle de redémarrage, replicas montés par erreur)
# au périmètre d'un seul environnement, pour qu'il n'assèche pas le nœud partagé
# avec l'autre.
#
# ⚠️ Le dimensionnement doit couvrir le PIC, pas l'état stable. Les Deployments
# de MicroCRM se déploient en `maxSurge: 1 / maxUnavailable: 0` : le nouveau pod
# est créé et devient prêt AVANT que l'ancien soit retiré, donc il existe un pod
# de plus pendant tout le rollout. Un quota calé sur le régime permanent laisse
# le cluster tourner parfaitement... jusqu'au déploiement suivant, où le pod
# excédentaire est refusé par l'admission avec un `exceeded quota` peu bavard —
# le Deployment reste bloqué sans que rien ne plante. Les valeurs sont fournies
# par l'appelant, qui connaît le nombre de replicas de son environnement.
resource "kubernetes_resource_quota_v1" "this" {
  metadata {
    name      = "${var.name}-quota"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    # Les clés portent la notation pointée de l'API Kubernetes, que les
    # variables ne peuvent pas reprendre (un identifiant HCL n'accepte pas le
    # point) : d'où la traduction ici plutôt qu'un `hard` passé tel quel.
    hard = {
      "pods"            = var.quota.pods
      "requests.cpu"    = var.quota.requests_cpu
      "requests.memory" = var.quota.requests_memory
      "limits.cpu"      = var.quota.limits_cpu
      "limits.memory"   = var.quota.limits_memory
    }
  }
}

# Le ResourceQuota plafonne la somme ; le LimitRange plafonne l'unité. Sans lui,
# un seul conteneur mal configuré peut consommer à lui seul tout le quota du
# namespace et affamer les autres — le total reste conforme, l'environnement est
# pourtant à l'arrêt.
#
# Il rend aussi le quota applicable : dès qu'un ResourceQuota porte sur
# `requests.*` ou `limits.*`, tout conteneur qui n'a pas la valeur
# correspondante est refusé à l'admission. Les `default` / `default_request`
# ci-dessous la lui donnent, ce qui évite qu'un `kubectl run` de débogage soit
# rejeté sans explication utile.
resource "kubernetes_limit_range_v1" "this" {
  metadata {
    name      = "${var.name}-limits"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    limit {
      type = "Container"

      # Pas de `min`, volontairement. Le front demande 10m de CPU et 32Mi : tout
      # plancher confortable à écrire le ferait rejeter à l'admission, et un
      # plancher assez bas pour le laisser passer ne protégerait de rien. Un
      # garde-fou qui n'interdit que le raisonnable est un piège, pas un
      # garde-fou.
      default = {
        cpu    = var.container_limits.default_limit_cpu
        memory = var.container_limits.default_limit_memory
      }

      default_request = {
        cpu    = var.container_limits.default_request_cpu
        memory = var.container_limits.default_request_memory
      }

      # ⚠️ `max` est un plafond DUR sur les `limits` déclarées par conteneur, pas
      # sur sa consommation réelle : un conteneur dont les `limits` dépassent ces
      # valeurs n'est pas bridé, il est purement REJETÉ à la création. Le back de
      # production demande 2 CPU / 1Gi ; descendre `max_cpu` sous « 2 » ou
      # `max_memory` sous « 1Gi » rendrait l'environnement indéployable, et
      # l'erreur remonte sur le ReplicaSet — pas sur le Deployment, qu'un
      # `kubectl get deploy` montre simplement figé. Toute baisse de ces valeurs
      # se vérifie contre les `resources.limits` des manifestes k8s/.
      max = {
        cpu    = var.container_limits.max_cpu
        memory = var.container_limits.max_memory
      }
    }
  }
}
