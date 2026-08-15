# Ces sorties lisent l'attribut des ressources et non les variables d'entrée,
# alors que la valeur est la même. C'est ce qui crée la dépendance : un appelant
# qui branche autre chose sur `module.namespace.name` attendra que le namespace
# existe réellement, au lieu de démarrer en parallèle et d'échouer sur un
# namespace absent.

output "name" {
  description = "Nom du namespace créé."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "quota_name" {
  description = "Nom du ResourceQuota du namespace."
  value       = kubernetes_resource_quota_v1.this.metadata[0].name
}

output "limit_range_name" {
  description = "Nom du LimitRange du namespace."
  value       = kubernetes_limit_range_v1.this.metadata[0].name
}

output "labels" {
  description = <<-EOT
    Labels d'identité posés par ce module.

    Sortis pour être passés au module network-policy : les policies vivent dans
    ce namespace et doivent répondre au même recensement
    (`-l app.kubernetes.io/managed-by=terraform`). Les recopier à la main dans
    l'environnement aurait suffi à les laisser diverger un jour.
  EOT
  value       = local.labels
}
