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

  # État local et séparé de celui de staging. La séparation est la seule chose
  # qui empêche une erreur de répertoire de détruire l'autre environnement : un
  # état unique aurait fait de `terraform destroy` en staging une commande
  # capable d'emporter la production.
  backend "local" {
    path = "terraform.tfstate"
  }
}
