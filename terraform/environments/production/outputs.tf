# Sorties de l'environnement de production.
# Voir terraform/environments/staging/outputs.tf pour les justifications.

output "namespace" {
  description = "Namespace créé. Doit correspondre à $PROD_NAMESPACE côté GitLab."
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
  description = "Contexte visé. À relire en premier quand un plan surprend."
  value       = var.kube_context
}
