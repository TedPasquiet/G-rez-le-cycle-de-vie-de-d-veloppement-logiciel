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
  # de l'image $TERRAFORM_IMAGE de la CI, celle des sorties consignées dans
  # TERRAFORM.md. Une exécution sur 1.5 n'a jamais été tentée.
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # `~> 3.2` autorise les correctifs (3.2.x, 3.3…) et interdit le passage
      # en 4.x, qui casserait la syntaxe des ressources. La version exacte
      # réellement utilisée est figée par .terraform.lock.hcl, lui versionné —
      # et pour TOUTES les plateformes qui exécutent Terraform sur ce projet,
      # pas seulement celle du poste (voir TERRAFORM.md §4.3).
      version = "~> 3.2"
    }
  }

  # ÉTAT PARTAGÉ ET VERROUILLÉ — état managé GitLab, via le backend `http`.
  #
  # Ce n'était pas le choix d'origine : le projet a démarré en backend `local`,
  # un fichier par environnement sur un seul poste. Ce qui a rendu la bascule
  # nécessaire, c'est l'ouverture à plusieurs personnes, et deux défauts que
  # l'état local ne pouvait pas corriger :
  #
  #   1. **Aucun verrou.** Deux `apply` simultanés corrompaient l'état. Tant
  #      qu'une seule personne appliquait depuis un seul poste, le risque était
  #      nul ; à deux, il est certain d'arriver un jour.
  #   2. **Un plan qui ne prouvait rien.** L'état n'étant jamais commité, la CI
  #      repartait d'un état VIDE à chaque exécution : le plan annonçait « tout
  #      à créer » quel que soit le contenu réel du cluster. Il ne pouvait
  #      structurellement détecter aucune dérive.
  #
  # L'état managé GitLab règle les deux : un état par environnement, hébergé par
  # le même GitLab que le dépôt, gratuit sur le Free Tier, avec verrou HTTP.
  #
  # Ce qui est ÉCRIT ICI est ce qui vaut pour tout le monde : les méthodes du
  # contrat GitLab. Elles ne portent aucun secret et n'ont aucune raison de
  # varier d'une exécution à l'autre.
  #
  # Ce qui est VOLONTAIREMENT ABSENT : l'adresse de l'état et les
  # identifiants. Une adresse écrite en dur porterait l'identifiant numérique du
  # projet GitLab et interdirait tout fork ou toute migration de dépôt ; des
  # identifiants en dur seraient un secret dans le dépôt. Les deux sont fournis
  # à `init` par les variables d'environnement `TF_HTTP_*`, que
  # scripts/ci/terraform_check.sh compose à partir de $TF_STATE_BASE_URL et du
  # nom de l'environnement. Voir TERRAFORM.md §4.
  backend "http" {
    lock_method   = "POST"
    unlock_method = "DELETE"

    # GitLab renvoie 409 quand l'état est déjà verrouillé. Sans attente, deux
    # jobs lancés dans la même seconde feraient échouer le second au lieu de le
    # faire patienter — ce qui arrive dès qu'un pipeline de MR et un pipeline de
    # branche se croisent.
    retry_wait_min = 5
  }
}
