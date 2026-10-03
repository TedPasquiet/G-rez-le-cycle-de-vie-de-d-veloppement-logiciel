#!/bin/sh
#
# release_notes.sh
#
# Ce script écrit la description de la Release GitLab d'une version : quelles
# images ont été promues, depuis quel commit, par quel pipeline.
#
# Le manque qu'il comble : un tag Git dit « cette version existe », pas ce
# qu'elle contient. La Release est la page où GitLab le dit — et tant qu'elle
# était vide, la question « quelle image est la 1.4.0 ? » se réglait en allant
# lire le registry. La description nomme donc les DEUX tags de chaque image, le
# numéro de version et le SHA : ils désignent le même digest, puisque la
# promotion est un retag et non une reconstruction (RELEASE.md §2.1).
#
# Il ne crée PAS la Release : c'est le mot-clé `release:` du job qui le fait,
# une fois ce fichier écrit. Il n'interroge ni le registry ni l'API — il ne
# fait que mettre en forme ce que GitLab pose déjà dans l'environnement du job.
#
# Il est écrit en sh POSIX et non en bash, comme validate_k8s.sh et pour la
# même raison : l'image du job (`glab`, basée sur Alpine) n'a que busybox sh,
# et un job de release n'a aucune raison de dépendre d'un miroir Alpine.
#
# Utilisation :
#   release_notes.sh <fichier de sortie>
#
# Variables d'environnement lues (toutes posées par GitLab ou par
# .gitlab/ci/variables.yml) :
#   CI_COMMIT_TAG        Le tag de release (obligatoire). Ex : v1.4.0
#   CI_COMMIT_SHA        Le commit taggué (obligatoire).
#   CI_REGISTRY_IMAGE    La racine des images du projet (obligatoire).
#   CI_COMMIT_SHORT_SHA  Le SHA court. À défaut : les 8 premiers caractères.
#   APP_BACK_NAME        Nom de l'image du back. Défaut : back
#   APP_FRONT_NAME       Nom de l'image du front. Défaut : front
#   CI_PIPELINE_URL      Lien du pipeline de tag (facultatif).
#   CI_PROJECT_URL       Lien du projet, pour pointer le commit (facultatif).
#
# Ce que renvoie le script :
#   0 = fichier écrit · 1 = paramètre ou variable manquante
#
# Exemple :
#   CI_COMMIT_TAG=v1.4.0 CI_COMMIT_SHA=$(git rev-parse HEAD) \
#   CI_REGISTRY_IMAGE=registry.gitlab.com/xxx \
#   scripts/ci/release_notes.sh reports/release-notes.md

set -eu

erreur() {
  echo "ERREUR : $1" >&2
  exit 1
}

case "${1:-}" in
  -h | --help)
    sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  '') erreur "fichier de sortie manquant (voir --help)" ;;
esac
sortie="$1"

# Une variable absente doit arrêter le job, pas produire une Release qui
# annonce l'image « :» ou le commit « » — c'est exactement le genre de page
# qu'on ne relit pas et qui trompe le jour où on en a besoin.
[ -n "${CI_COMMIT_TAG:-}" ] || erreur "CI_COMMIT_TAG est vide : ce script ne sert que sur un pipeline de tag"
[ -n "${CI_COMMIT_SHA:-}" ] || erreur "CI_COMMIT_SHA est vide"
[ -n "${CI_REGISTRY_IMAGE:-}" ] || erreur "CI_REGISTRY_IMAGE est vide"

# Le tag d'image ne porte pas le « v » (RELEASE.md §2.1).
version="${CI_COMMIT_TAG#v}"
sha_court="${CI_COMMIT_SHORT_SHA:-$(printf '%.8s' "$CI_COMMIT_SHA")}"
back="${CI_REGISTRY_IMAGE}/${APP_BACK_NAME:-back}"
front="${CI_REGISTRY_IMAGE}/${APP_FRONT_NAME:-front}"

if [ -n "${CI_PROJECT_URL:-}" ]; then
  commit="[\`$sha_court\`]($CI_PROJECT_URL/-/commit/$CI_COMMIT_SHA)"
else
  commit="\`$CI_COMMIT_SHA\`"
fi

mkdir -p "$(dirname "$sortie")"

{
  echo "## MicroCRM $version"
  echo
  echo "Commit : $commit"
  [ -z "${CI_PIPELINE_URL:-}" ] || echo "Pipeline de release : $CI_PIPELINE_URL"
  echo
  echo "### Images promues"
  echo
  echo "| Composant | Version | Image éprouvée (même digest) |"
  echo "| --------- | ------- | ---------------------------- |"
  echo "| back | \`$back:$version\` | \`$back:$sha_court\` |"
  echo "| front | \`$front:$version\` | \`$front:$sha_court\` |"
  echo
  echo "Ces images n'ont pas été reconstruites pour la release : ce sont celles"
  echo "que le pipeline du commit a construites, scannées et mises sous charge,"
  echo "auxquelles le numéro de version a été ajouté (retag)."
  echo
  echo "La mise en production reste une action manuelle : job"
  echo "\`deploy-production\` de ce pipeline."
} >"$sortie"

echo "Description de la release écrite dans $sortie"
