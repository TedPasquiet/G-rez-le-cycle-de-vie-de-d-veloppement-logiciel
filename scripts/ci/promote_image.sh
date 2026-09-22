#!/usr/bin/env bash
#
# promote_image.sh
#
# Ce script pose un numéro de version SemVer sur une image DÉJÀ construite et
# déjà poussée, puis renvoie l'image ainsi taguée au registry.
#
# Il ne construit rien, et c'est tout son intérêt. RELEASE.md §1 pose le
# principe « on promeut, on ne reconstruit pas » : la version doit désigner
# exactement l'image qui a traversé les tests, pas une image reconstruite à
# partir des mêmes sources. Deux builds du même commit produisent des couches
# différentes (horodatages, résolution de paquets) ; seul un retag garantit que
# `back:1.4.0` et `back:a1b2c3d` sont le même digest.
#
# En gros il fait :
#   1. il vérifie que la version est bien du SemVer
#   2. il se connecte au registry
#   3. il tire l'image construite, désignée par son tag de commit
#   4. il lui ajoute le tag de version et le pousse
#
# Les options :
#   -i, --image <ref>      Nom de l'image sans le tag (obligatoire).
#                          Ex : registry.gitlab.com/xxx/back
#   -f, --from-tag <sha>   Tag de l'image à promouvoir (obligatoire), en
#                          général le SHA court du commit.
#   -v, --version <vX.Y.Z> Le numéro de version (obligatoire). Le « v » de tête
#                          est accepté et retiré du tag d'image.
#   -h, --help             Affiche l'aide.
#
# Les variables d'environnement pour se connecter au registry (fournies par la
# CI, jamais écrites en dur dans le code) :
#   REGISTRY_HOST      L'adresse du registry (ex : registry.gitlab.com)
#   REGISTRY_USER      L'utilisateur (ex : $CI_REGISTRY_USER)
#   REGISTRY_PASSWORD  Le mot de passe / token (ex : $CI_REGISTRY_PASSWORD)
#
# Ce que renvoie le script :
#   0 = tout va bien · 1 = problème de config/exécution
#
# Exemple :
#   REGISTRY_HOST=$CI_REGISTRY REGISTRY_USER=$CI_REGISTRY_USER \
#   REGISTRY_PASSWORD=$CI_REGISTRY_PASSWORD \
#   scripts/ci/promote_image.sh -i "$CI_REGISTRY_IMAGE/back" \
#     -f "$CI_COMMIT_SHORT_SHA" -v "$CI_COMMIT_TAG"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

# Grammaire officielle de semver.org, avec un « v » de tête optionnel parce que
# c'est la forme qu'on donne aux tags Git (`git tag v1.4.0`).
readonly SEMVER_RE='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?$'

main() {
  local image='' from_tag='' version=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i | --image) image="${2:?}"; shift 2 ;;
      -f | --from-tag) from_tag="${2:?}"; shift 2 ;;
      -v | --version) version="${2:?}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  [[ -n "$image" ]] || die "Paramètre manquant : --image"
  [[ -n "$from_tag" ]] || die "Paramètre manquant : --from-tag"
  [[ -n "$version" ]] || die "Paramètre manquant : --version"

  # Les métadonnées de build SemVer (`1.4.0+exp.sha.5114f85`) sont refusées, et
  # volontairement : un tag Docker n'accepte pas le `+`. On pourrait le traduire
  # en `_`, mais le tag d'image cesserait alors d'être identique au tag Git —
  # or c'est précisément l'égalité des deux qui rend une version traçable.
  if [[ "$version" == *'+'* ]]; then
    die "Version refusée : '$version' — un tag Docker n'accepte pas le caractère '+' des métadonnées de build SemVer"
  fi
  if [[ ! "$version" =~ $SEMVER_RE ]]; then
    die "Version refusée : '$version' n'est pas du SemVer (attendu vX.Y.Z, éventuellement suivi de -alpha.1)"
  fi

  require_cmd docker
  require_env REGISTRY_HOST REGISTRY_USER REGISTRY_PASSWORD

  # Le tag d'image ne porte pas le « v » : c'est la convention des registries
  # (`node:22-alpine`, `postgres:16-alpine`), et le tag Git le garde.
  local ref_source="$image:$from_tag" ref_version="$image:${version#v}"

  log_info "Connexion au registry $REGISTRY_HOST"
  printf '%s' "$REGISTRY_PASSWORD" \
    | docker login "$REGISTRY_HOST" --username "$REGISTRY_USER" --password-stdin \
    || die "Échec de l'authentification au registry"

  # On tire depuis le registry plutôt que de compter sur le cache local du
  # runner : c'est ce qui prouve qu'on promeut bien l'image publiée, celle que
  # les étapes précédentes ont scannée et mise sous charge.
  # Pas de `retry` ici, contrairement au push. L'échec attendu à cet endroit
  # n'est pas un aléa réseau mais une image qui n'existe pas : on tague un
  # commit dont le pipeline n'a jamais poussé d'image. Réessayer quinze
  # secondes pour l'apprendre n'aide personne, et le message doit dire la vraie
  # cause plutôt que « échec après 3 tentatives ».
  log_info "Récupération de l'image construite : $ref_source"
  docker pull "$ref_source" \
    || die "Image introuvable au registry : '$ref_source' — on ne promeut que ce qui a été construit et testé. Vérifier que le pipeline du commit taggué a bien poussé son image."

  log_info "Promotion de $ref_source en $ref_version"
  docker tag "$ref_source" "$ref_version" || die "Échec du retag de l'image"

  retry 3 5 docker push "$ref_version"

  log_info "Version livrée : $ref_version (même image que $ref_source)"
}

main "$@"
