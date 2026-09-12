# Versions et emplacement de l'état, pour l'environnement de production.
#
# Strictement identique à celui de staging, et c'est délibéré : deux
# environnements qui ne tournent pas avec le même Terraform ni le même provider
# ne prouvent rien l'un de l'autre. Les justifications détaillées sont dans
# terraform/environments/staging/versions.tf, elles ne sont pas répétées ici.

terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  # État managé GitLab, verrouillé, et surtout SÉPARÉ de celui de staging :
  # l'adresse est composée à partir du nom de l'environnement, donc chaque
  # environnement a son propre état côté GitLab. Cette séparation est la seule
  # chose qui empêche une erreur de répertoire de détruire l'autre
  # environnement : avec un état unique, un `terraform destroy` lancé dans
  # staging aurait pu emporter la production.
  backend "http" {
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}
