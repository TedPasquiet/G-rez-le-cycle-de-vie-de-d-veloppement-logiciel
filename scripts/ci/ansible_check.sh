#!/usr/bin/env bash
#
# ansible_check.sh
#
# Contrôle la configuration Ansible du dépôt sans rien modifier : le gabarit du
# playbook (`--syntax-check`), puis la qualité des rôles (`ansible-lint`).
#
# Pourquoi un script plutôt que trois lignes dans un bloc `script:` du
# `.gitlab-ci.yml` : ici c'est rejouable en local à l'identique, relu par
# ShellCheck, et testable avec de faux outils (`scripts/tests/stubs/`). Un bloc
# YAML ne se teste qu'en poussant un commit et en attendant le pipeline.
#
# ⚠️ Et surtout, la raison d'être du script tient en une ligne : le `cd` dans
#    `ansible/`. Ansible ne lit `ansible.cfg` que si c'est le répertoire
#    courant. Depuis la racine du dépôt, `ansible-lint ansible/` l'ignore EN
#    SILENCE — il ne se plaint pas, il regarde ailleurs : plus d'inventaire,
#    plus de `roles_path`, plus de configuration de projet. Le contrôle sort
#    alors en 0 sans avoir contrôlé grand-chose, ce qui est pire que pas de
#    contrôle du tout, parce qu'on lui fait confiance. Détail dans ANSIBLE.md
#    §8 et dans l'en-tête d'`ansible/ansible.cfg`.
#
# Rien de ce que lance ce script n'écrit quoi que ce soit : `--syntax-check`
# analyse le playbook sans exécuter la moindre tâche, et `ansible-lint` ne fait
# que lire. C'est ce qui le rend exécutable en CI, où il n'y a ni poste à
# préparer ni cluster à créer.
#
# Les échecs s'additionnent au lieu d'arrêter le script au premier : si le
# gabarit est cassé, on veut quand même savoir ce que le linter a à dire.
# Deux erreurs vues en une exécution valent mieux que deux allers-retours.
#
# Les options :
#   -d, --dir <répertoire>  Le répertoire Ansible, interprété depuis le dossier
#                           courant. Par défaut : ansible
#       --collections       Installe d'abord les collections de requirements.yml.
#                           Pas fait par défaut, et ce n'est pas un oubli : le
#                           paquet `ansible` complet les embarque déjà, donc ce
#                           serait un téléchargement pour rien à chaque
#                           pipeline. Indispensable en revanche sur une image
#                           bâtie sur `ansible-core`, qui n'embarque aucune
#                           collection — voir ansible/requirements.yml.
#   -h, --help              Affiche l'aide.
#
# Variable d'environnement :
#   ANSIBLE_DIR   Même rôle que --dir, pour la CI qui pose ses chemins par
#                 variables. L'option l'emporte si les deux sont données.
#
# Ce que renvoie le script :
#   0 = tout passe · 1 = au moins un contrôle a échoué, ou un prérequis manque
#
# Exemples :
#   scripts/ci/ansible_check.sh
#   scripts/ci/ansible_check.sh --collections    # image CI bâtie sur ansible-core

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

main() {
  local ansible_dir="${ANSIBLE_DIR:-ansible}" collections='false'
  # Compteur d'échecs plutôt qu'un `die` immédiat : c'est lui qui permet de
  # rendre les deux diagnostics en une fois.
  local -i echecs=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d | --dir) ansible_dir="${2:?}"; shift 2 ;;
      --collections) collections='true'; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  require_cmd ansible-playbook ansible-lint
  [[ -d "$ansible_dir" ]] || die "Répertoire Ansible introuvable : '$ansible_dir' (voir --dir)"

  # ⚠️ Le cœur du script (voir l'en-tête). On entre dans le répertoire au lieu
  # de le passer en argument aux outils, sinon `ansible.cfg` n'est jamais lu et
  # les deux contrôles suivants perdent leur configuration sans le dire.
  cd "$ansible_dir" || die "Impossible d'entrer dans '$ansible_dir'"
  log_info "Contrôles lancés depuis $PWD — c'est là, et seulement là, qu'ansible.cfg est lu"

  # Vérifiés après le `cd`, donc par leur nom seul : c'est exactement ainsi que
  # les outils les chercheront, et un chemin absent ici vaut mieux qu'un
  # message d'Ansible sur un fichier « vide ou introuvable ».
  [[ -f site.yml ]] || die "Playbook introuvable : $PWD/site.yml"

  if [[ "$collections" == 'true' ]]; then
    [[ -f requirements.yml ]] || die "Fichier introuvable : $PWD/requirements.yml"
    log_info "Installation des collections déclarées dans requirements.yml"
    # Un `retry` parce que c'est un téléchargement depuis Galaxy : un échec
    # isolé vient du réseau, pas du dépôt. Et un `die` plutôt qu'un échec
    # comptabilisé : sans les collections, `--syntax-check` signalerait des
    # modules manquants et le diagnostic qui suit serait faux plutôt
    # qu'incomplet.
    retry 3 5 ansible-galaxy collection install -r requirements.yml
  fi

  # `--syntax-check` d'abord : il coûte une seconde et attrape une faute de
  # gabarit — un `{{` non refermé, une clé mal indentée — que le linter
  # rapporterait de façon bien plus obscure, parce qu'il échouerait à charger
  # le fichier avant d'avoir une règle à appliquer.
  log_info "Gabarit du playbook : ansible-playbook --syntax-check site.yml"
  if ansible-playbook --syntax-check site.yml; then
    log_info "Gabarit valide"
  else
    log_error "Le playbook ne se charge pas — corriger avant de lire le rapport du linter"
    echecs=$((echecs + 1))
  fi

  # Sans argument, volontairement : ansible-lint part du répertoire courant et
  # de la configuration du projet pour découvrir ce qu'il doit analyser. Lui
  # passer un chemin restreindrait l'analyse à ce chemin et laisserait dans
  # l'ombre tout ce qu'on aurait oublié de nommer.
  log_info "Qualité des rôles : ansible-lint"
  if ansible-lint; then
    log_info "Aucune remarque du linter"
  else
    log_error "ansible-lint signale au moins une violation (détail ci-dessus)"
    echecs=$((echecs + 1))
  fi

  ((echecs == 0)) || die "$echecs contrôle(s) Ansible en échec"
  log_info "Tous les contrôles Ansible passent"
}

main "$@"
