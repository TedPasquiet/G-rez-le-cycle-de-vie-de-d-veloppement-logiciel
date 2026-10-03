#!/usr/bin/env bash
#
# trivy_scan.sh
#
# Ce script lance un scan Trivy et en garde une TRACE : un rapport JSON et un
# tableau lisible, écrits dans des fichiers que la CI publie en artefacts.
#
# Le manque qu'il comble : jusqu'ici Trivy n'écrivait que dans le journal du
# job. Un constat se lisait le jour où le job rougissait, puis disparaissait
# avec le journal. Rien n'était exploitable par un autre outil — en particulier
# par scripts/ci/collect_security.py, qui indexe ces rapports dans
# Elasticsearch pour le tableau de bord « sécurité ».
#
# En gros il fait :
#   1. le RELEVÉ : un premier passage en `--format json`, sans porte, écrit
#      dans le fichier demandé par --report ;
#   2. la PORTE : un second passage, au format tableau, avec le code de sortie
#      bloquant. Sa sortie part dans le journal ET dans un fichier `.txt` voisin
#      du rapport JSON.
#
# ⚠️ Deux passages, et pas un seul suivi de `trivy convert`. `convert` saurait
# rejouer la porte sur le JSON, mais il lui faut le fichier : or dans les jobs
# `package-*`, Trivy tourne dans un conteneur lancé par `docker run` contre un
# démon dind, et un fichier du job n'y est visible que par un montage dont le
# chemin dépend de la configuration du runner. Le JSON sort donc par la sortie
# standard du conteneur, qui, elle, marche partout. Le second passage réutilise
# la base de vulnérabilités et l'analyse des couches déjà en cache : il coûte
# quelques secondes.
#
# ⚠️ Le relevé ne masque jamais la porte. Si le premier passage échoue, c'est
# une erreur technique (code 1) : un rapport qu'on n'a pas pu écrire ne doit
# pas laisser croire que le scan a eu lieu. Et le code de sortie du script est
# celui de la porte — jamais celui du relevé.
#
# ⚠️ Le rapport est filtré comme la porte (mêmes sévérités, même fichier
# d'exclusions). Il décrit donc ce que la porte a vu, pas tout ce que Trivy
# sait : un constat MEDIUM n'y figure pas, un constat exclu par
# `.trivyignore.yaml` non plus.
#
# Les options :
#   -m, --mode <fs|image>       Ce qu'on scanne (obligatoire) : un répertoire
#                               ou une image.
#   -T, --target <cible>        Le répertoire ou la référence d'image
#                               (obligatoire). Ex : `.` ou `registry/x/back:abc`
#   -r, --report <fichier>      Le rapport JSON à écrire (obligatoire).
#                               Ex : reports/trivy-fs.json. Le tableau est écrit
#                               à côté, même nom, extension `.txt`.
#   -s, --severity <liste>      Sévérités bloquantes. Défaut : HIGH,CRITICAL
#       --scanners <liste>      Scanners (mode fs). Défaut de Trivy si absent.
#       --ignorefile <fichier>  Fichier d'exclusions (voir .trivyignore.yaml).
#       --docker-image <image>  Lance Trivy par `docker run <image>` au lieu du
#                               binaire local. C'est le mode des jobs
#                               `package-*`, dont l'image n'embarque pas Trivy.
#                               Réservé au mode image, sans --ignorefile : aucun
#                               fichier du dépôt n'est monté dans ce conteneur.
#   -h, --help                  Affiche l'aide.
#
# Ce que renvoie le script :
#   0 = aucun constat bloquant · 1 = problème de config ou scan impossible
#   2 = au moins un constat bloquant (la porte est fermée)
#
# Exemples :
#   scripts/ci/trivy_scan.sh -m fs -T . -r reports/trivy-fs.json \
#     --scanners vuln,secret,misconfig --ignorefile .trivyignore.yaml
#   scripts/ci/trivy_scan.sh -m image -T "$IMAGE:$CI_COMMIT_SHORT_SHA" \
#     -r reports/trivy-image-back.json --docker-image "$TRIVY_IMAGE"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

# Code que Trivy renvoie quand la porte se ferme. Pas 1 : Trivy sort déjà en 1
# sur une erreur fatale (base injoignable, image introuvable), et les deux cas
# ne se traitent pas de la même façon — l'un se corrige dans le code, l'autre
# se rejoue.
readonly CODE_CONSTATS=2

main() {
  local mode='' target='' report='' severity='HIGH,CRITICAL'
  local scanners='' ignorefile='' docker_image=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m | --mode) mode="${2:?}"; shift 2 ;;
      -T | --target) target="${2:?}"; shift 2 ;;
      -r | --report) report="${2:?}"; shift 2 ;;
      -s | --severity) severity="${2:?}"; shift 2 ;;
      --scanners) scanners="${2:?}"; shift 2 ;;
      --ignorefile) ignorefile="${2:?}"; shift 2 ;;
      --docker-image) docker_image="${2:?}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  [[ -n "$mode" ]] || die "Paramètre manquant : --mode"
  [[ -n "$target" ]] || die "Paramètre manquant : --target"
  [[ -n "$report" ]] || die "Paramètre manquant : --report"
  [[ "$mode" == 'fs' || "$mode" == 'image' ]] \
    || die "Mode inconnu : '$mode' (attendu : fs ou image)"
  [[ "$report" == *.json ]] \
    || die "Le rapport doit porter l'extension .json : '$report'"

  if [[ -n "$ignorefile" && ! -f "$ignorefile" ]]; then
    # Trivy, lui, continue sans rien dire quand le fichier est absent : toutes
    # les exclusions sautent et la porte se ferme sur des faux positifs connus.
    die "Fichier d'exclusions introuvable : '$ignorefile'"
  fi

  # La commande Trivy : le binaire local, ou le même binaire dans un conteneur.
  local -a trivy=(trivy)
  if [[ -n "$docker_image" ]]; then
    [[ "$mode" == 'image' ]] \
      || die "--docker-image ne vaut que pour --mode image : le répertoire à scanner n'est pas monté dans le conteneur"
    [[ -z "$ignorefile" ]] \
      || die "--ignorefile est incompatible avec --docker-image : aucun fichier du dépôt n'est monté dans le conteneur"
    require_cmd docker
    # Le volume nommé garde la base de vulnérabilités et l'analyse des couches
    # d'un passage à l'autre. Un volume NOMMÉ et non un chemin : il vit dans le
    # démon (dind compris), il ne dépend d'aucun chemin du job.
    trivy=(docker run --rm
      -v /var/run/docker.sock:/var/run/docker.sock
      -v trivy-cache:/root/.cache/
      "$docker_image")
  else
    require_cmd trivy
  fi

  local -a args=("$mode" --severity "$severity" --no-progress)
  [[ -n "$scanners" ]] && args+=(--scanners "$scanners")
  [[ -n "$ignorefile" ]] && args+=(--ignorefile "$ignorefile")

  local tableau="${report%.json}.txt"
  mkdir -p "$(dirname "$report")"

  # Le relevé est écrit HORS de l'arbre scanné, puis déplacé. En mode fs, la
  # cible est souvent `.` : un rapport posé dedans serait lu par le second
  # passage, et un constat de secret recopié dans le JSON y serait retrouvé.
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064  # on veut la valeur de $tmp MAINTENANT
  trap "rm -f '$tmp' '$tmp.txt'" EXIT

  log_info "Relevé Trivy ($mode) de '$target' -> $report"
  if ! "${trivy[@]}" "${args[@]}" --format json --quiet "$target" >"$tmp"; then
    die "Le relevé JSON a échoué : scan impossible (base de vulnérabilités injoignable, cible introuvable ?). Aucun rapport n'est écrit."
  fi
  [[ -s "$tmp" ]] || die "Le relevé JSON est vide : Trivy n'a rien écrit sur sa sortie standard."

  log_info "Porte Trivy ($mode) sur '$target' — sévérités bloquantes : $severity"
  local -i code=0
  "${trivy[@]}" "${args[@]}" --exit-code "$CODE_CONSTATS" "$target" | tee "$tmp.txt" || code="${PIPESTATUS[0]}"

  # Les fichiers ne rejoignent le dépôt qu'APRÈS la porte, et dans tous les
  # cas : c'est quand la porte se ferme que le rapport sert le plus.
  mv "$tmp" "$report"
  mv "$tmp.txt" "$tableau"
  # mktemp crée en 600 : lisible du seul propriétaire, ce qui gêne quiconque
  # ouvre l'artefact téléchargé sous un autre compte.
  chmod 644 "$report" "$tableau"
  log_info "Rapports écrits : $report et $tableau"

  case "$code" in
    0)
      log_info "Aucun constat $severity."
      ;;
    "$CODE_CONSTATS")
      log_error "Constats $severity détectés — la porte est fermée. Détail dans $tableau."
      exit "$CODE_CONSTATS"
      ;;
    *)
      die "Trivy a échoué (code $code) : ce n'est pas un constat, c'est un scan qui n'a pas abouti."
      ;;
  esac
}

main "$@"
