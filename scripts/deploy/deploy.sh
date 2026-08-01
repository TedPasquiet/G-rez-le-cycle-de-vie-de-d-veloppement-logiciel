#!/usr/bin/env bash
#
# deploy.sh
#
# Ce script déploie une image sur Kubernetes. L'idée c'est de changer l'image
# d'un Deployment, puis d'attendre que ça se passe bien. Et si ça se passe mal,
# il fait automatiquement machine arrière pour ne pas laisser l'appli cassée.
#
# Étape par étape :
#   1. il vérifie les prérequis (kubectl, kubeconfig, les options)
#   2. il change l'image avec `kubectl set image`
#   3. il attend la fin du déploiement avec `kubectl rollout status` (avec un délai max)
#   4. si ça rate ou si c'est trop long, il annule tout seul avec `rollout undo`
#      pour revenir à la version d'avant, et il sort en erreur.
#
# Les options :
#   -n, --namespace <ns>    Le namespace Kubernetes (obligatoire). Ex : staging
#   -d, --deployment <name> Le nom du Deployment (obligatoire). Ex : back
#   -c, --container <name>  Le nom du conteneur à mettre à jour (obligatoire).
#   -i, --image <ref>       L'image complète avec son tag (obligatoire).
#                           Ex : registry.gitlab.com/xxx/back:<sha>
#   -t, --timeout <dur>     Le temps max qu'on attend. Par défaut : 180s
#       --no-auto-rollback  Pour désactiver le retour arrière automatique.
#   -h, --help              Affiche l'aide.
#
# Variable d'environnement :
#   KUBECONFIG   Le fichier de connexion au cluster (donné par la CI, jamais commité).
#
# Ce que renvoie le script :
#   0 = ok · 1 = problème de config · 3 = le déploiement a raté (retour arrière fait)
#
# Exemple :
#   KUBECONFIG=$PWD/kube.cfg scripts/deploy/deploy.sh \
#     -n staging -d back -c back -i "$CI_REGISTRY_IMAGE/back:$CI_COMMIT_SHORT_SHA"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

main() {
  local namespace='' deployment='' container='' image='' timeout='180s' auto_rollback='true'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --namespace) namespace="${2:?}"; shift 2 ;;
      -d | --deployment) deployment="${2:?}"; shift 2 ;;
      -c | --container) container="${2:?}"; shift 2 ;;
      -i | --image) image="${2:?}"; shift 2 ;;
      -t | --timeout) timeout="${2:?}"; shift 2 ;;
      --no-auto-rollback) auto_rollback='false'; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  [[ -n "$namespace" ]] || die "Paramètre manquant : --namespace"
  [[ -n "$deployment" ]] || die "Paramètre manquant : --deployment"
  [[ -n "$container" ]] || die "Paramètre manquant : --container"
  [[ -n "$image" ]] || die "Paramètre manquant : --image"

  require_cmd kubectl
  require_env KUBECONFIG

  # On vérifie d'abord que le Deployment existe, avant de toucher à quoi que ce soit.
  kubectl -n "$namespace" get deployment "$deployment" >/dev/null 2>&1 \
    || die "Deployment '$deployment' introuvable dans le namespace '$namespace'"

  log_info "Déploiement de $image sur $namespace/$deployment (conteneur : $container)"
  kubectl -n "$namespace" set image "deployment/$deployment" "$container=$image" \
    || die "Échec de la mise à jour de l'image"

  log_info "Attente de la fin du rollout (timeout : $timeout)"
  if kubectl -n "$namespace" rollout status "deployment/$deployment" --timeout="$timeout"; then
    log_info "Déploiement réussi : $namespace/$deployment -> $image"
    exit 0
  fi

  log_error "Le déploiement n'a pas abouti dans le temps prévu"
  if [[ "$auto_rollback" == 'true' ]]; then
    log_warn "On revient automatiquement à la version précédente"
    kubectl -n "$namespace" rollout undo "deployment/$deployment" \
      || log_error "Le rollback automatique a lui aussi échoué — intervention manuelle requise"
  fi
  exit 3
}

main "$@"
