# Sorties de l'environnement de staging.
#
# Elles servent à deux choses : vérifier après coup ce qui a été créé, et
# donner à la CI le nom du namespace sans qu'elle ait à le deviner
# (`terraform output -raw namespace`).

output "namespace" {
  description = "Namespace créé. Doit correspondre à $STAGING_NAMESPACE côté GitLab."
  value       = module.namespace.name
}

output "quota_name" {
  description = "Nom du ResourceQuota, pour un `kubectl describe quota`."
  value       = module.namespace.quota_name
}

output "limit_range_name" {
  description = "Nom du LimitRange, pour un `kubectl describe limitrange`."
  value       = module.namespace.limit_range_name
}

output "network_policies" {
  description = "NetworkPolicy posées. Liste vide si network_policy_enabled = false."
  value       = module.network_policy.policy_names
}

output "kube_context" {
  description = <<-EOT
    Contexte visé par cette exécution.

    Sorti volontairement : c'est la première chose à relire quand un plan
    montre la création de ressources qu'on croyait déjà en place — le plus
    souvent, il vise un autre cluster que celui qu'on regarde.
  EOT
  value       = var.kube_context
}
