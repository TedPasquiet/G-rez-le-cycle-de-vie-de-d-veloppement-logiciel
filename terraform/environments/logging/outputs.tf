# Voir terraform/environments/staging/outputs.tf pour les justifications.

output "namespace" {
  description = "Namespace créé. C'est lui que prend le `-n` du `kubectl apply -k k8s/elk`."
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

output "kube_context" {
  description = "Contexte visé. À relire en premier quand un plan surprend."
  value       = var.kube_context
}

output "apm_network_policy" {
  description = "NetworkPolicy qui n'ouvre APM Server qu'aux namespaces applicatifs, pour un `kubectl -n logging describe networkpolicy`."
  value       = kubernetes_network_policy_v1.allow_apps_to_apm_server.metadata[0].name
}
