#!/usr/bin/env bash
#
# rollback.sh
#
# Ce script sert à revenir en arrière sur Kubernetes quand une version pose
# problème en prod. Il remet la version d'avant (ou une version précise si on
# lui demande).
#
# Étape par étape :
#   1. il vérifie les prérequis (kubectl, kubeconfig, les options)
#   2. il fait `kubectl rollout undo` :
#        - vers la version d'avant par défaut,
#        - ou vers une version précise si on met --to-revision.
#   3. il attend que ce soit fini et vérifie que ça a marché.
#
# Les options :
#   -n, --namespace <ns>     Le namespace Kubernetes (obligatoire).
#   -d, --deployment <name>  Le nom du Deployment (obligatoire).
#   -r, --to-revision <num>  Une version précise. Par défaut : celle d'avant.
#                            (pour voir la liste : kubectl rollout history)
#   -t, --timeout <dur>      Le temps max qu'on attend. Par défaut : 180s
#   -h, --help               Affiche l'aide.
#
# Variable d'environnement :
#   KUBECONFIG   Le fichier de connexion au cluster (donné par la CI).
#
# Ce que renvoie le script :
#   0 = ok · 1 = problème de config · 3 = le rollback a raté
#
# Exemple :
#   KUBECONFIG=$PWD/kube.cfg scripts/deploy/rollback.sh -n production -d back

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  local namespace='' deployment='' to_revision='' timeout='180s'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --namespace) namespace="${2:?}"; shift 2 ;;
      -d | --deployment) deployment="${2:?}"; shift 2 ;;
      -r | --to-revision) to_revision="${2:?}"; shift 2 ;;
      -t | --timeout) timeout="${2:?}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  [[ -n "$namespace" ]] || die "Paramètre manquant : --namespace"
  [[ -n "$deployment" ]] || die "Paramètre manquant : --deployment"

  require_cmd kubectl
  require_env KUBECONFIG

  kubectl -n "$namespace" get deployment "$deployment" >/dev/null 2>&1 \
    || die "Deployment '$deployment' introuvable dans le namespace '$namespace'"

  local -a undo_cmd=(kubectl -n "$namespace" rollout undo "deployment/$deployment")
  if [[ -n "$to_revision" ]]; then
    undo_cmd+=(--to-revision="$to_revision")
    log_info "Rollback de $namespace/$deployment vers la révision $to_revision"
  else
    log_info "Rollback de $namespace/$deployment vers la révision précédente"
  fi

  "${undo_cmd[@]}" || die "Échec de la commande de rollback"

  log_info "Attente de la stabilisation (timeout : $timeout)"
  if kubectl -n "$namespace" rollout status "deployment/$deployment" --timeout="$timeout"; then
    log_info "Rollback réussi : $namespace/$deployment"
    exit 0
  fi

  log_error "Le rollout de rollback n'a pas abouti — intervention manuelle requise"
  exit 3
}

main "$@"
