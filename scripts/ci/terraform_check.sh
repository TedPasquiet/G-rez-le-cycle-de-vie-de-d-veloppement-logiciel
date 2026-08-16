#!/usr/bin/env bash
#
# terraform_check.sh
#
# Passe les environnements Terraform du dépôt au contrôle, depuis la CI comme
# depuis un poste. C'est le pendant de scripts/tests/validate_k8s.sh pour le
# lot Terraform : la logique vit dans un script versionné plutôt que dans un
# bloc `script:` du .gitlab-ci.yml, donc elle se rejoue en local, se relit avec
# ShellCheck et se teste avec un faux `terraform` (scripts/tests/stubs/terraform).
#
# Deux modes, parce qu'ils n'ont ni le même coût ni la même valeur de preuve :
#
#   --validate (défaut)  Ne parle à AUCUN cluster. `terraform fmt -check` sur
#                        tout l'arbre, puis `init -backend=false` + `validate`
#                        pour chaque environnement. C'est le mode que la CI
#                        peut jouer sur n'importe quel runner.
#   --plan               `init` puis `plan` pour chaque environnement. Demande
#                        un kubeconfig, et ne prouve pas ce qu'on croit — lire
#                        l'avertissement plus bas, il est mesuré.
#
# ⚠️ Ce que `--plan` ne détecte PAS
#   Un plan sort en 0 même si le cluster visé est injoignable, et l'état étant
#   local et jamais commité (TERRAFORM.md §4), la CI repart toujours d'un état
#   vide : le plan annonce donc « tout à créer » quel que soit le contenu réel
#   du cluster. Ce mode vérifie que la configuration se résout, pas l'écart
#   entre le dépôt et la réalité. Le script le redit à l'exécution.
#
# Les options :
#   -d <répertoire>   Répertoire contenant un sous-répertoire par environnement.
#                     Par défaut : terraform/environments, surchargeable aussi
#                     par $TERRAFORM_ENVS_DIR.
#       --validate    Mode fmt + init -backend=false + validate (défaut).
#       --plan        Mode init + plan.
#       --apply       Mode init + apply -auto-approve. EXIGE -e.
#   -e <nom>          Restreint le traitement à un seul environnement.
#                     Facultatif pour --validate et --plan, OBLIGATOIRE pour
#                     --apply : appliquer en boucle sur tous les environnements
#                     ferait passer la production dans le même geste que le
#                     staging, sans que rien ne le distingue à la lecture du job.
#   -h, --help        Affiche l'aide.
#
# Variable d'environnement :
#   TERRAFORM_ENVS_DIR   Même rôle que -d ; l'option a la priorité.
#
# Ce que renvoie le script :
#   0 = tous les contrôles passent · 1 = au moins un a échoué, ou la
#   configuration du script elle-même est invalide.
#
# Tous les environnements sont traités, même après un échec : deux erreurs se
# lisent en une exécution au lieu de deux.
#
# Exemples :
#   scripts/ci/terraform_check.sh
#   scripts/ci/terraform_check.sh --plan -d terraform/environments
#   scripts/ci/terraform_check.sh --apply -e production

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

# Lance une commande en la nommant, et renvoie 1 si elle échoue — sans arrêter
# l'appelant, qui doit pouvoir continuer sur l'environnement suivant.
#
# Le code de sortie réel est affiché parce qu'il porte une information que « ça
# a raté » n'a pas : `terraform fmt -check` sort en 3 quand un fichier est mal
# formaté, en 1 quand il n'a pas su lire un fichier. Le script ne teste donc
# jamais l'égalité à 1, seulement « non nul » — présumer 1 ferait passer le
# défaut le plus courant pour un succès.
lance() {
  local libelle="$1"
  shift

  log_info "$libelle"
  local code=0
  "$@" || code=$?

  if ((code != 0)); then
    log_error "$libelle : échec (code de sortie $code)"
    return 1
  fi
  return 0
}

main() {
  local envs_dir="${TERRAFORM_ENVS_DIR:-terraform/environments}"
  local mode='validate'
  local env_unique=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) envs_dir="${2:?}"; shift 2 ;;
      -e) env_unique="${2:?}"; shift 2 ;;
      --validate) mode='validate'; shift ;;
      --plan) mode='plan'; shift ;;
      --apply) mode='apply'; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  # ⚠️ Le garde-fou le plus important du script. `--apply` écrit dans un vrai
  # cluster ; le laisser boucler sur tous les environnements ferait appliquer la
  # production dans le même geste que le staging, et un job de CI qui fait ça ne
  # le dit nulle part dans son nom. Exiger -e oblige à écrire l'environnement
  # visé dans le pipeline, donc à le relire à chaque modification.
  if [[ "$mode" == 'apply' && -z "$env_unique" ]]; then
    die "--apply exige -e <environnement> : appliquer sur tous les environnements à la fois n'est pas une opération qu'on lance sans la nommer"
  fi

  require_cmd terraform

  [[ -d "$envs_dir" ]] \
    || die "Répertoire des environnements introuvable : '$envs_dir' (option -d ou \$TERRAFORM_ENVS_DIR)"

  # Les environnements sont DÉCOUVERTS, jamais listés en dur : une liste figée
  # ferait ignorer un troisième environnement en silence, et un job vert qui
  # n'a rien contrôlé est pire qu'un job absent.
  local -a envs=()
  local chemin
  for chemin in "$envs_dir"/*/; do
    [[ -d "$chemin" ]] || continue
    envs+=("${chemin%/}")
  done
  ((${#envs[@]} > 0)) \
    || die "Aucun environnement dans '$envs_dir' : il faut un sous-répertoire par environnement (ex. staging/, production/)"

  # Le filtre s'applique APRÈS la découverte, pour qu'un `-e` mal orthographié
  # échoue en nommant ce qui existe, plutôt que de traiter zéro environnement
  # et de sortir en 0 — un contrôle qui n'a rien contrôlé doit être un échec.
  if [[ -n "$env_unique" ]]; then
    local -a filtre=()
    for chemin in "${envs[@]}"; do
      [[ "$(basename "$chemin")" == "$env_unique" ]] && filtre+=("$chemin")
    done
    ((${#filtre[@]} > 0)) \
      || die "Environnement '$env_unique' introuvable dans '$envs_dir'. Disponibles : $(for c in "${envs[@]}"; do basename "$c"; done | tr '\n' ' ')"
    envs=("${filtre[@]}")
  fi

  local echecs=0
  local env nom

  if [[ "$mode" == 'validate' ]]; then
    # `fmt` porte sur le parent du répertoire des environnements, pas sur les
    # environnements eux-mêmes : les modules sont leurs FRÈRES (terraform/modules),
    # pas leurs descendants, et un module mal formaté doit être signalé ici
    # plutôt qu'à la revue.
    local racine_tf
    racine_tf="$(dirname "$envs_dir")"

    lance "Format de l'arbre Terraform '$racine_tf'" \
      terraform fmt -check -recursive "$racine_tf" \
      || { echecs=$((echecs + 1)); log_warn "Correction : terraform fmt -recursive $racine_tf"; }
  else
    # Averti à l'exécution, et pas seulement dans l'en-tête : la sortie d'un job
    # se lit sans le script sous les yeux, et « Plan: 6 to add » est exactement
    # le genre de ligne qu'on prend pour une preuve.
    log_warn "Mode --plan : un plan sort en 0 même si le cluster est injoignable, et l'état repart de zéro à chaque exécution (TERRAFORM.md §4)."
    log_warn "Un « X to add » ne dit donc RIEN de l'écart réel entre le dépôt et le cluster — ce mode contrôle la résolution de la configuration, pas la dérive."
  fi

  for env in "${envs[@]}"; do
    nom="$(basename "$env")"

    if [[ "$mode" == 'validate' ]]; then
      # `-backend=false` fait toute la différence entre les deux modes : sans
      # lui, `init` résout le backend, donc toucherait l'état (et exigerait des
      # identifiants le jour où le backend `http` du §4 sera en place). Ce qui
      # reste contacté, c'est le registre des providers — le mode est hors ligne
      # vis-à-vis du CLUSTER, pas du réseau.
      if ! lance "[$nom] Initialisation sans backend" \
        terraform -chdir="$env" init -backend=false -input=false -no-color; then
        # Sans init, `validate` échouerait de toute façon en réclamant les
        # providers : l'enchaîner ajouterait une erreur qui masque la vraie.
        echecs=$((echecs + 1))
        log_warn "[$nom] Validation non jouée : l'initialisation a échoué"
        continue
      fi

      lance "[$nom] Validation de la configuration" \
        terraform -chdir="$env" validate -no-color \
        || echecs=$((echecs + 1))
    elif [[ "$mode" == 'apply' ]]; then
      if ! lance "[$nom] Initialisation" \
        terraform -chdir="$env" init -input=false -no-color; then
        echecs=$((echecs + 1))
        log_warn "[$nom] Apply non joué : l'initialisation a échoué"
        continue
      fi

      # `-auto-approve` est inévitable dans un job de CI, qui n'a personne pour
      # répondre. C'est précisément pour cela que `-e` est obligatoire en amont :
      # la confirmation interactive qu'on perd ici est remplacée par
      # l'obligation d'écrire l'environnement visé dans le pipeline.
      #
      # ⚠️ Sur un environnement dont le namespace préexiste, cet apply échoue sur
      # « already exists » tant que l'objet n'a pas été importé (TERRAFORM.md
      # §10.1). L'échec est le bon comportement : importer automatiquement
      # reviendrait à adopter sans le dire des ressources créées par quelqu'un
      # d'autre.
      lance "[$nom] Application" \
        terraform -chdir="$env" apply -auto-approve -input=false -no-color \
        || echecs=$((echecs + 1))
    else
      if ! lance "[$nom] Initialisation" \
        terraform -chdir="$env" init -input=false -no-color; then
        echecs=$((echecs + 1))
        log_warn "[$nom] Plan non joué : l'initialisation a échoué"
        continue
      fi

      # FAIT MESURÉ, à ne pas redécouvrir : avec un `config_path` qui n'existe
      # pas, `plan` ÉCHOUE ('config_path' refers to an invalid path: stat …: no
      # such file or directory) ; avec un kubeconfig valide pointant sur un
      # cluster ÉTEINT, il sort en 0 et annonce « Plan: 6 to add ». Autrement
      # dit ce mode exige qu'un FICHIER kubeconfig existe, jamais qu'un cluster
      # réponde. Combiné à l'état local jamais commité, il ne peut structurellement
      # détecter aucune dérive.
      #
      # `-input=false` n'est pas décoratif : sans lui, une variable sans défaut
      # ferait attendre une saisie et le job resterait bloqué jusqu'au timeout.
      lance "[$nom] Plan" \
        terraform -chdir="$env" plan -input=false -no-color \
        || echecs=$((echecs + 1))
    fi
  done

  if ((echecs > 0)); then
    log_error "Bilan : $echecs contrôle(s) en échec sur ${#envs[@]} environnement(s) (mode $mode)"
    exit 1
  fi

  log_info "Bilan : tout est passé sur ${#envs[@]} environnement(s) (mode $mode)"
  exit 0
}

main "$@"
