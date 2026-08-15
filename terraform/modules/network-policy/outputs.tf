output "policy_names" {
  description = "Noms des NetworkPolicy créées, dans l'ordre refus puis autorisations. Liste vide si enabled = false."
  # Les splats `[*]` sur des ressources en `count` rendent la liste vide d'eux-
  # mêmes quand le module est désactivé : pas de conditionnel à maintenir en
  # double du `count`, et surtout un appelant qui consomme cette sortie sans
  # avoir à connaître l'état du drapeau.
  #
  # Sortie destinée aux assertions de recette et aux messages de sortie d'un
  # environnement — elle n'expose délibérément pas les ressources elles-mêmes,
  # qui donneraient à l'appelant prise sur la forme interne du module.
  value = concat(
    kubernetes_network_policy_v1.default_deny_ingress[*].metadata[0].name,
    kubernetes_network_policy_v1.allow_ingress_to_front[*].metadata[0].name,
    kubernetes_network_policy_v1.allow_ingress_to_back[*].metadata[0].name,
  )
}
