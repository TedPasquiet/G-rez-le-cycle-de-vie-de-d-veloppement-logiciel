#!/usr/bin/env bash
#
# common.sh
#
# Petit fichier de fonctions que je réutilise dans mes autres scripts, pour ne
# pas réécrire les mêmes choses partout (les logs, les vérifications, etc.).
#
# Attention : ce fichier ne se lance pas tout seul, on le "source" au début des
# autres scripts, comme ça :
#   source "$(dirname "$0")/../lib/common.sh"
#
# Ce que je peux utiliser après l'avoir sourcé :
#   log_info / log_warn / log_error  -> afficher un message
#   die <message>                    -> afficher une erreur et arrêter le script
#   require_cmd <cmd...>             -> vérifier qu'une commande existe
#   require_env <VAR...>            -> vérifier qu'une variable est bien remplie
#   retry <n> <delai> <cmd...>      -> réessayer une commande plusieurs fois

# Ces 3 options rendent le script plus sûr : il s'arrête dès qu'il y a une erreur,
# une variable non définie, ou un souci dans un pipe (au lieu de continuer bêtement).
set -o errexit
set -o nounset
set -o pipefail

# On met de la couleur seulement si on est dans un vrai terminal.
# Dans les logs de la CI ça ne sert à rien, donc on laisse vide.
if [[ -t 2 ]]; then
  readonly _C_RED=$'\033[0;31m'
  readonly _C_YELLOW=$'\033[0;33m'
  readonly _C_GREEN=$'\033[0;32m'
  readonly _C_RESET=$'\033[0m'
else
  readonly _C_RED='' _C_YELLOW='' _C_GREEN='' _C_RESET=''
fi

# Fonction interne qui fait l'affichage. Les fonctions log_* juste en dessous
# l'appellent avec la bonne couleur. On écrit sur stderr pour ne pas polluer
# la sortie normale du script.
_log() {
  local color="$1" level="$2"
  shift 2
  printf '%s[%s] %-5s%s %s\n' \
    "$color" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$_C_RESET" "$*" >&2
}

log_info() { _log "$_C_GREEN" "INFO" "$@"; }
log_warn() { _log "$_C_YELLOW" "WARN" "$@"; }
log_error() { _log "$_C_RED" "ERROR" "$@"; }

# Affiche une erreur puis arrête tout de suite le script (code 1).
die() {
  log_error "$@"
  exit 1
}

# Vérifie que les commandes passées existent bien (ex: docker, kubectl).
# Si une manque, on arrête avec un message clair au lieu d'un plantage bizarre.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Commande requise introuvable : '$cmd'"
  done
}

# Vérifie que les variables d'environnement demandées sont bien remplies.
# Important : on n'affiche jamais leur valeur, parce que ça peut être un secret (token).
require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      die "Variable d'environnement requise manquante ou vide : '$var'"
    fi
  done
}

# Réessaie une commande plusieurs fois avec une petite pause entre chaque essai.
# Pratique pour le réseau (push d'image, appel d'API) qui peut échouer une fois
# par hasard puis remarcher juste après.
retry() {
  local -i max="$1" delay="$2"
  shift 2
  local -i attempt=1
  until "$@"; do
    if ((attempt >= max)); then
      die "Échec après $max tentative(s) : $*"
    fi
    log_warn "Tentative $attempt/$max échouée, nouvel essai dans ${delay}s : $*"
    sleep "$delay"
    ((attempt++))
  done
}
