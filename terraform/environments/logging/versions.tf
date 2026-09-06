# Versions et emplacement de l'état, pour le namespace de la stack ELK.
#
# Identique aux deux environnements applicatifs, et c'est le sujet : ce
# troisième environnement n'existe pas seulement pour porter ELK, il PROUVE que
# les modules de terraform/modules/ sont réutilisables. Tant qu'ils n'avaient
# servi que deux fois, sur deux environnements jumeaux, l'affirmation ne valait
# rien. Voir terraform/environments/staging/versions.tf pour les justifications.

terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}
