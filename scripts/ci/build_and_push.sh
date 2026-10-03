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
# ⚠️ L'ordre 4 puis 5 est une garantie, pas un détail : une image qui ne passe
# pas le scan n'atteint JAMAIS le registry. Tant que le scan était une ligne à
# part dans le job, après ce script, l'image était poussée puis scannée — et un
# tag de release posé sur ce commit aurait promu une image refusée par la
# porte, puisque promote_image.sh ne demande qu'une chose : que le tag du SHA
# existe. Constaté le 2026-10-02 : `back:5bf1d6a2` était au registry avec cinq
# CVE hautes, alors que son job `package-back` était rouge.
#
# Les options :
#   -c, --context <dir>    Dossier à builder (obligatoire). Ex : ./back
#   -i, --image <ref>      Nom de l'image sans le tag (obligatoire).
#                          Ex : registry.gitlab.com/xxx/back
#   -t, --tag <sha>        Le tag fixe, en général le SHA du commit (obligatoire).
#   -m, --moving-tag <t>   Le tag mobile en plus. Par défaut : latest
#   -f, --dockerfile <f>   Chemin du Dockerfile. Par défaut : <context>/Dockerfile
#   -s, --scan             Lance le scan Trivy avant le push. Le scan lui-même
#                          est fait par trivy_scan.sh, qui en garde un relevé.
#       --scan-severity <l> Sévérités qui annulent le push.
#                          Par défaut : HIGH,CRITICAL
#       --scan-report <f>  Rapport JSON du scan (le tableau est écrit à côté,
#                          en .txt). Par défaut : reports/trivy-image.json
#       --trivy-image <i>  Lance Trivy par `docker run <i>` plutôt que par un
#                          binaire local : c'est le cas des jobs de CI, dont
#                          l'image n'embarque pas Trivy.
#   -h, --help             Affiche l'aide.
#
# Les variables d'environnement pour se connecter au registry (fournies par la
# CI, jamais écrites en dur dans le code) :
#   REGISTRY_HOST      L'adresse du registry (ex : registry.gitlab.com)
#   REGISTRY_USER      L'utilisateur (ex : $CI_REGISTRY_USER)
#   REGISTRY_PASSWORD  Le mot de passe / token (ex : $CI_REGISTRY_PASSWORD)
#
# Ce que renvoie le script :
#   0 = tout va bien · 1 = problème de config/exécution (scan impossible compris)
#   2 = image trop vulnérable, push annulé
#
# Exemple :
#   REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
#   REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
#   scripts/ci/build_and_push.sh -c ./back -i "$CI_REGISTRY_IMAGE/back" \
#     -t "$CI_COMMIT_SHORT_SHA" --scan \
#     --scan-report reports/trivy-image-back.json --trivy-image "$TRIVY_IMAGE"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

main() {
  local context='' image='' tag='' moving_tag='latest' dockerfile='' scan='false'
  local scan_severity='HIGH,CRITICAL' scan_report='reports/trivy-image.json' trivy_image=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c | --context) context="${2:?}"; shift 2 ;;
      -i | --image) image="${2:?}"; shift 2 ;;
      -t | --tag) tag="${2:?}"; shift 2 ;;
      -m | --moving-tag) moving_tag="${2:?}"; shift 2 ;;
      -f | --dockerfile) dockerfile="${2:?}"; shift 2 ;;
      -s | --scan) scan='true'; shift ;;
      --scan-severity) scan_severity="${2:?}"; shift 2 ;;
      --scan-report) scan_report="${2:?}"; shift 2 ;;
      --trivy-image) trivy_image="${2:?}"; shift 2 ;;
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
    # Le scan est délégué à trivy_scan.sh plutôt que réécrit ici : c'est lui
    # qui sait produire le relevé JSON, et deux façons de lancer Trivy dans le
    # même dépôt finiraient par ne plus poser la même porte.
    local -a scan_args=(--mode image --target "$ref_immutable"
      --report "$scan_report" --severity "$scan_severity")
    [[ -n "$trivy_image" ]] && scan_args+=(--docker-image "$trivy_image")

    # Le code de trivy_scan.sh est repris tel quel : 2 = des constats (l'image
    # est refusée), 1 = le scan n'a pas pu avoir lieu. Dans les deux cas on ne
    # pousse pas — une image qu'on n'a pas pu scanner n'est pas une image saine.
    local -i scan_code=0
    bash "$(dirname "${BASH_SOURCE[0]}")/trivy_scan.sh" "${scan_args[@]}" || scan_code=$?
    if ((scan_code == 2)); then
      log_error "Vulnérabilités $scan_severity détectées — push annulé"
      exit 2
    elif ((scan_code != 0)); then
      die "Scan Trivy impossible — push annulé (une image non scannée n'est pas une image saine)"
    fi
  fi

  log_info "Push de $ref_immutable"
  retry 3 5 docker push "$ref_immutable"
  log_info "Push de $ref_moving"
  retry 3 5 docker push "$ref_moving"

  log_info "Image livrée : $ref_immutable"
}

main "$@"
