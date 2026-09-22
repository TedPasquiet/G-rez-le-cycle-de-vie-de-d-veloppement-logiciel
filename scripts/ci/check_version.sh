#!/usr/bin/env bash
#
# check_version.sh
#
# Ce script vérifie que le numéro de version déclaré dans le dépôt correspond
# bien au tag de release qu'on est en train de poser.
#
# Le tag Git reste la source de vérité (RELEASE.md §2.1). Les fichiers du dépôt
# le répètent, parce qu'un artefact doit pouvoir dire sa propre version sans
# qu'on aille interroger Git : un `package.json` livré, un jar dans un rapport
# de dépendances, un `helm list` sur un cluster. Répéter une valeur, c'est
# accepter qu'elle diverge — d'où ce contrôle, qui échoue avant la promotion
# plutôt qu'après la mise en production.
#
# Les fichiers contrôlés, et pourquoi ceux-là :
#   front/package.json          version du front livré
#   back/build.gradle           version du jar produit
#   helm/microcrm/Chart.yaml    appVersion : la version de l'APPLICATION déployée
#
# Deux versions sont délibérément HORS périmètre :
#   package.json (racine)       c'est l'outillage du dépôt (hooks, lint,
#                               commitlint), pas l'application livrée. Il porte
#                               d'ailleurs un autre nom : microcrm-tooling.
#   Chart.yaml `version`        c'est la version du CHART, que la convention
#                               Helm distingue de celle de l'application. Le
#                               chart peut changer (une sonde, un label) sans
#                               que l'application bouge, et l'inverse.
#
# Les options :
#   -v, --version <vX.Y.Z>  La version attendue (obligatoire). En CI :
#                           $CI_COMMIT_TAG. Le « v » de tête est accepté.
#   -h, --help              Affiche l'aide.
#
# Ce que renvoie le script :
#   0 = tout concorde · 1 = problème de config · 2 = au moins une divergence
#
# Exemple :
#   scripts/ci/check_version.sh --version "$CI_COMMIT_TAG"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

# Extrait une version d'un fichier. Écrit la valeur trouvée sur stdout, ou rien
# si le motif ne mord pas — ce cas est traité comme une erreur par l'appelant,
# et pas comme une version vide : un champ renommé doit faire échouer le
# contrôle, jamais le faire passer en silence.
lit_version() {
  local fichier="$1" motif="$2"
  [[ -f "$fichier" ]] || return 1
  sed -n "s/$motif/\\1/p" "$fichier" | head -n 1
}

main() {
  local version=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v | --version) version="${2:?}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  [[ -n "$version" ]] || die "Paramètre manquant : --version"

  # On compare sans le « v » : le tag Git est `v1.4.0`, les fichiers portent
  # `1.4.0`. Même convention que le tag d'image (RELEASE.md §2.1).
  local attendue="${version#v}"

  local racine
  racine="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  # fichier | motif sed (groupe 1 = la version) | libellé
  local -a controles=(
    "front/package.json|.*\"version\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*|version du front"
    "back/build.gradle|^version[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*|version du jar"
    "helm/microcrm/Chart.yaml|^appVersion:[[:space:]]*'\\{0,1\\}\\([^']*[^' ]\\)'\\{0,1\\}[[:space:]]*$|appVersion du chart"
  )

  local -i divergences=0
  local ligne fichier motif libelle trouvee

  log_info "Version attendue : $attendue (tag '$version')"

  for ligne in "${controles[@]}"; do
    IFS='|' read -r fichier motif libelle <<<"$ligne"

    if [[ ! -f "$racine/$fichier" ]]; then
      log_error "$fichier — fichier introuvable"
      divergences+=1
      continue
    fi

    trouvee="$(lit_version "$racine/$fichier" "$motif")"

    if [[ -z "$trouvee" ]]; then
      log_error "$fichier — aucune version trouvée ($libelle). Le champ a-t-il été renommé ?"
      divergences+=1
    elif [[ "$trouvee" != "$attendue" ]]; then
      log_error "$fichier — $libelle vaut '$trouvee', attendu '$attendue'"
      divergences+=1
    else
      log_info "$fichier — $libelle : $trouvee"
    fi
  done

  if ((divergences > 0)); then
    log_error "$divergences divergence(s). Aligner les fichiers sur le tag, ou poser le tag qui correspond aux fichiers."
    exit 2
  fi

  log_info "Toutes les versions déclarées concordent avec le tag."
}

main "$@"
