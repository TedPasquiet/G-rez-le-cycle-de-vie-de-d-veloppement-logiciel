#!/usr/bin/env bash
#
# run_k6.sh
#
# Ce script lance les tests de performance k6 (dossier tests/k6/). C'est juste
# un raccourci : il choisit le bon fichier de scénario, note où écrire le
# rapport, et traduit le code de sortie de k6 en quelque chose de lisible.
#
# Toute la logique du test (charge, seuils, parcours) est dans les fichiers
# tests/k6/*.js, pas ici : comme ça le job CI et la commande locale mesurent
# exactement la même chose.
#
# Les scénarios :
#   smoke    quelques requêtes, 1 utilisateur — « est-ce que ça marche ? »
#   load     la charge nominale attendue — c'est lui qui porte les seuils
#   stress   on pousse jusqu'à la rupture pour connaître la marge disponible
#
# Les options :
#   -s, --scenario <nom>     smoke, load ou stress. Par défaut : smoke.
#   -u, --url <url>          L'URL de l'API à tester.
#                            Par défaut : http://localhost:8080
#   -o, --output-dir <dir>   Où écrire le rapport JSON. Par défaut : reports/k6
#       --no-report          Ne pas écrire de rapport (juste l'affichage).
#   -h, --help               Affiche l'aide.
#   --                       Tout ce qui suit est passé tel quel à k6.
#                            Ex : -- --vus 20 --duration 1m
#
# On peut aussi régler les seuils et la charge par variables d'environnement
# (K6_LOAD_VUS, K6_P95_READ_MS...) : la liste est en tête de tests/k6/lib/config.js.
#
# Ce que renvoie le script :
#   0 = tout va bien
#   1 = problème de configuration (option ou scénario inconnu, k6 absent)
#   2 = les seuils de performance ne sont pas tenus
#   3 = le test n'a pas pu aller au bout (API injoignable, k6 en erreur)
#
# Exemples :
#   scripts/tests/run_k6.sh
#   scripts/tests/run_k6.sh --scenario load --url http://back:8080
#   K6_LOAD_VUS=25 scripts/tests/run_k6.sh -s load

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

# Les codes de sortie de k6, qu'on retraduit en codes à nous.
readonly K6_SEUILS_DEPASSES=99

main() {
  local racine scenario='smoke' url='' dossier_rapport='reports/k6' avec_rapport=1
  local -a options_k6=()

  racine="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s | --scenario) scenario="${2:?}"; shift 2 ;;
      -u | --url) url="${2:?}"; shift 2 ;;
      -o | --output-dir) dossier_rapport="${2:?}"; shift 2 ;;
      --no-report) avec_rapport=0; shift ;;
      -h | --help) usage; exit 0 ;;
      --) shift; options_k6=("$@"); break ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  local fichier="$racine/tests/k6/$scenario.js"
  [[ -f "$fichier" ]] \
    || die "Scénario inconnu : '$scenario' (attendu : smoke, load ou stress)"

  require_cmd k6

  # --url l'emporte sur une éventuelle variable déjà présente : c'est l'option
  # la plus explicite, donc la plus prioritaire.
  if [[ -n "$url" ]]; then
    export K6_BASE_URL="$url"
  fi

  local -a commande=(k6 run)

  if ((avec_rapport)); then
    mkdir -p "$dossier_rapport" || die "Impossible de créer le dossier '$dossier_rapport'"
    commande+=(--summary-export "$dossier_rapport/$scenario-summary.json")
  fi

  if ((${#options_k6[@]} > 0)); then
    commande+=("${options_k6[@]}")
  fi

  commande+=("$fichier")

  log_info "Scénario '$scenario' sur ${K6_BASE_URL:-http://localhost:8080 (défaut)}"

  # `|| code=$?` évite que errexit coupe le script : on veut récupérer le code
  # de k6 pour le traduire proprement juste en dessous.
  local code=0
  "${commande[@]}" || code=$?

  case "$code" in
    0)
      log_info "Scénario '$scenario' : seuils de performance tenus"
      ;;
    "$K6_SEUILS_DEPASSES")
      log_error "Scénario '$scenario' : seuils de performance dépassés (détail au-dessus)"
      exit 2
      ;;
    *)
      log_error "k6 s'est arrêté en erreur (code $code) — API injoignable ou script en défaut"
      exit 3
      ;;
  esac

  if ((avec_rapport)); then
    log_info "Rapport : $dossier_rapport/$scenario-summary.json"
  fi
}

main "$@"
