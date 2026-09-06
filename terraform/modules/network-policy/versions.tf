# Aucun bloc `provider` ici, et aucun `backend` : un module partagé qui
# configurerait son propre provider imposerait ses coordonnées de cluster à tous
# ses appelants, et Terraform interdit ensuite de le retirer proprement (un
# module à provider embarqué ne peut plus être détruit une fois sa configuration
# disparue). Le module hérite du provider de l'environnement appelant, qui seul
# sait à quel cluster il parle.

terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # `~> 3.2` autorise les correctifs et les mineures de la branche 3, mais
      # bloque le passage à 4 : les majeures de ce provider renomment ou
      # suppriment des ressources, et une montée silencieuse se solderait par un
      # plan qui propose de détruire les policies — donc de rouvrir le trafic.
      version = "~> 3.2"
    }
  }
}
