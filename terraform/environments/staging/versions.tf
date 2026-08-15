# Versions et emplacement de l'état, pour l'environnement de staging.
#
# Même discipline que les images d'outillage du .gitlab-ci.yml : tout est figé.
# Un provider qui change de version sans qu'aucun commit ne le dise produit un
# plan différent d'une exécution à l'autre, et l'écart est très difficile à
# imputer après coup.

terraform {
  # Ce plancher est une POLITIQUE, pas une contrainte technique, et il vaut
  # mieux le dire que de l'habiller : cette configuration n'utilise rien de plus
  # récent que les contraintes de type `object` et un bloc `validation`,
  # disponibles depuis la 0.13. Le plancher est placé à 1.5 pour ne pas tourner
  # sur une ligne qui ne reçoit plus de correctifs.
  #
  # La seule version réellement exercée est **1.15.7** — celle du poste, celle
  # des sorties consignées dans TERRAFORM.md. Une exécution sur 1.5 n'a jamais
  # été tentée.
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # `~> 3.2` autorise les correctifs (3.2.x, 3.3…) et interdit le passage
      # en 4.x, qui casserait la syntaxe des ressources. La version exacte
      # réellement utilisée est figée par .terraform.lock.hcl, lui versionné.
      version = "~> 3.2"
    }
  }

  # État local, dans le répertoire de l'environnement, et jamais commité
  # (terraform/.gitignore). C'est le choix qu'impose la décision D2 : tout le
  # projet tourne en local, il n'existe aucun bucket ni base pour héberger un
  # état distant.
  #
  # Ce que ça coûte, et qu'il faut savoir défendre : pas de verrou entre deux
  # exécutions concurrentes, et un état qui vit sur un seul poste. Tant qu'une
  # seule personne applique, depuis un seul poste, le risque est nul. Dès qu'un
  # job de CI appliquerait, il faudrait un état partagé — le chemin de
  # migration est écrit dans TERRAFORM.md §4, et il ne demande qu'un bloc
  # `backend "http"` pointant sur l'état managé de GitLab, gratuit sur le Free
  # Tier.
  backend "local" {
    path = "terraform.tfstate"
  }
}
