#!/usr/bin/env bash
#
# build_and_push.sh
#
# Ce script construit une image Docker et l'envoie sur le registry (l'étape
# "livraison" du pipeline). J'ai mis ça dans un script plutôt que directement
# dans le .gitlab-ci.yml pour que ce soit plus propre et réutilisable.
#
# En gros il fait :
#   1. il vérifie que tout est là (docker, le dossier à builder, les identifiants)
#   2. il se connecte au registry
#   3. il build l'image avec 2 tags : le SHA du commit + un tag "mobile" (latest)
#   4. si on demande --scan, il passe Trivy dessus et s'arrête si c'est trop grave
#   5. il push les 2 tags
#
# Les options :
#   -c, --context <dir>    Dossier à builder (obligatoire). Ex : ./back
#   -i, --image <ref>      Nom de l'image sans le tag (obligatoire).
#                          Ex : registry.gitlab.com/xxx/back
#   -t, --tag <sha>        Le tag fixe, en général le SHA du commit (obligatoire).
#   -m, --moving-tag <t>   Le tag mobile en plus. Par défaut : latest
#   -f, --dockerfile <f>   Chemin du Dockerfile. Par défaut : <context>/Dockerfile
#   -s, --scan             Lance le scan Trivy avant le push.
#   -h, --help             Affiche l'aide.
#
# Les variables d'environnement pour se connecter au registry (fournies par la
# CI, jamais écrites en dur dans le code) :
#   REGISTRY_HOST      L'adresse du registry (ex : registry.gitlab.com)
#   REGISTRY_USER      L'utilisateur (ex : $CI_REGISTRY_USER)
#   REGISTRY_PASSWORD  Le mot de passe / token (ex : $CI_REGISTRY_PASSWORD)
#
# Ce que renvoie le script :
#   0 = tout va bien · 1 = problème de config/exécution · 2 = image trop vulnérable
#
# Exemple :
#   REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
#   REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
#   scripts/ci/build_and_push.sh -c ./back -i "$CI_REGISTRY_IMAGE/back" \
#     -t "$CI_COMMIT_SHORT_SHA" --scan

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local context='' image='' tag='' moving_tag='latest' dockerfile='' scan='false'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c | --context) context="${2:?}"; shift 2 ;;
      -i | --image) image="${2:?}"; shift 2 ;;
      -t | --tag) tag="${2:?}"; shift 2 ;;
      -m | --moving-tag) moving_tag="${2:?}"; shift 2 ;;
      -f | --dockerfile) dockerfile="${2:?}"; shift 2 ;;
      -s | --scan) scan='true'; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  # On vérifie que les options obligatoires ont bien été données.
  [[ -n "$context" ]] || die "Paramètre manquant : --context"
  [[ -n "$image" ]] || die "Paramètre manquant : --image"
  [[ -n "$tag" ]] || die "Paramètre manquant : --tag"
  [[ -d "$context" ]] || die "Contexte de build introuvable : '$context'"
  dockerfile="${dockerfile:-$context/Dockerfile}"
  [[ -f "$dockerfile" ]] || die "Dockerfile introuvable : '$dockerfile'"

  require_cmd docker
  require_env REGISTRY_HOST REGISTRY_USER REGISTRY_PASSWORD

  local ref_immutable="$image:$tag" ref_moving="$image:$moving_tag"

  log_info "Connexion au registry $REGISTRY_HOST"
  printf '%s' "$REGISTRY_PASSWORD" \
    | docker login "$REGISTRY_HOST" --username "$REGISTRY_USER" --password-stdin \
    || die "Échec de l'authentification au registry"

  log_info "Build de $ref_immutable (Dockerfile : $dockerfile)"
  docker build \
    --tag "$ref_immutable" \
    --tag "$ref_moving" \
    --file "$dockerfile" \
    "$context" \
    || die "Échec du build de l'image"

  if [[ "$scan" == 'true' ]]; then
    require_cmd trivy
    log_info "Scan de vulnérabilités (Trivy) sur $ref_immutable"
    if ! trivy image --severity CRITICAL --exit-code 1 --no-progress "$ref_immutable"; then
      log_error "Vulnérabilités CRITICAL détectées — push annulé"
      exit 2
    fi
  fi

  log_info "Push de $ref_immutable"
  retry 3 5 docker push "$ref_immutable"
  log_info "Push de $ref_moving"
  retry 3 5 docker push "$ref_moving"

  log_info "Image livrée : $ref_immutable"
}

main "$@"
