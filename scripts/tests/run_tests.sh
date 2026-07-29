#!/usr/bin/env bash
#
# run_tests.sh
#
# Ce script teste les autres scripts du dossier `scripts/`. C'est le point de
# vigilance "tester chaque script dans un environnement contrôlé" : au lieu de
# le faire à la main, la CI le fait à chaque commit (job `test-scripts`).
#
# Comment ça marche :
#   Rien n'est réellement construit ni déployé. Je remplace `kubectl`, `docker`
#   et `trivy` par de faux programmes (dossier `stubs/`) que je mets en premier
#   dans le PATH. Ils notent ce qu'on leur demande dans un fichier et renvoient
#   le code de sortie que le test veut. Du coup je peux vérifier :
#     - que chaque script renvoie le bon code de sortie dans chaque situation,
#     - qu'il lance bien la bonne commande (ex : le rollback automatique),
#     - qu'il s'arrête proprement quand il manque un paramètre ou un secret.
#   Pour les scripts Python, j'utilise des faux rapports JaCoCo (`fixtures/`).
#
# Utilisation :
#   scripts/tests/run_tests.sh          # depuis n'importe quel dossier
#
# Ce que renvoie le script :
#   0 = tous les tests passent · 1 = au moins un test a échoué
#
# Prérequis : bash et python3. Aucune dépendance à installer.

# SC2016 = "les $ ne sont pas remplacés entre guillemets simples". Ici c'est
# voulu : je passe des bouts de script à `bash -c '...'`, et c'est ce bash-là
# qui doit remplacer $0 et $1, pas celui qui lit ce fichier.
# shellcheck disable=SC2016

# Attention : pas de `errexit` ici, contrairement aux autres scripts. Je veux
# que tous les tests s'exécutent même si l'un d'eux échoue, pour avoir le
# bilan complet à la fin.
set -o nounset
set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
FIXTURES_DIR="$TESTS_DIR/fixtures"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Les faux kubectl/docker/trivy passent avant les vrais.
export PATH="$TESTS_DIR/stubs:$PATH"

nb_ok=0
nb_ko=0
derniere_sortie=''

# --------------------------------------------------------------------------
# Petites fonctions d'assertion
# --------------------------------------------------------------------------

titre() { printf '\n== %s\n' "$1"; }

ok() {
  printf '   ok    %s\n' "$1"
  nb_ok=$((nb_ok + 1))
}

ko() {
  printf '   ÉCHEC %s\n         -> %s\n' "$1" "$2"
  nb_ko=$((nb_ko + 1))
}

# verifie_code <code attendu> <description> <commande...>
# Lance la commande, garde sa sortie dans $derniere_sortie et compare le code
# de retour à celui qu'on attend.
verifie_code() {
  local attendu="$1" description="$2"
  shift 2
  local obtenu
  derniere_sortie="$("$@" 2>&1)"
  obtenu=$?
  if [[ "$obtenu" == "$attendu" ]]; then
    ok "$description"
  else
    ko "$description" "code attendu $attendu, obtenu $obtenu"
  fi
}

# verifie_contient <texte> <description> — regarde dans la sortie du dernier
# `verifie_code`.
verifie_contient() {
  if [[ "$derniere_sortie" == *"$1"* ]]; then
    ok "$2"
  else
    ko "$2" "le texte '$1' est absent de la sortie"
  fi
}

verifie_contient_pas() {
  if [[ "$derniere_sortie" != *"$1"* ]]; then
    ok "$2"
  else
    ko "$2" "le texte '$1' ne devrait pas apparaître dans la sortie"
  fi
}

# verifie_fichier_contient <fichier> <texte> <description>
# Sert à vérifier ce qui a été demandé aux faux kubectl/docker.
verifie_fichier_contient() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    ok "$3"
  else
    ko "$3" "'$2' introuvable dans le journal du stub"
  fi
}

verifie_fichier_contient_pas() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    ko "$3" "'$2' ne devrait pas avoir été appelé"
  else
    ok "$3"
  fi
}

# Remet à zéro le journal d'un stub avant chaque scénario.
nouveau_journal() {
  local fichier="$WORK_DIR/journal-$1.txt"
  : >"$fichier"
  echo "$fichier"
}

# ==========================================================================
# lib/common.sh
# ==========================================================================
titre 'lib/common.sh'

verifie_code 1 'require_env échoue si la variable est vide' \
  env VAR_DE_TEST='' bash -c 'source "$0"; require_env VAR_DE_TEST' "$ROOT_DIR/scripts/lib/common.sh"
verifie_contient_pas 'VAR_DE_TEST=' "require_env n'affiche pas la valeur de la variable"

verifie_code 0 'require_env passe si la variable est remplie' \
  env VAR_DE_TEST='ok' bash -c 'source "$0"; require_env VAR_DE_TEST' "$ROOT_DIR/scripts/lib/common.sh"

verifie_code 1 "require_cmd échoue si la commande n'existe pas" \
  bash -c 'source "$0"; require_cmd commande_qui_nexiste_pas' "$ROOT_DIR/scripts/lib/common.sh"

verifie_code 0 'require_cmd passe pour une commande existante' \
  bash -c 'source "$0"; require_cmd bash' "$ROOT_DIR/scripts/lib/common.sh"

verifie_code 1 "retry abandonne après le nombre d'essais prévu" \
  bash -c 'source "$0"; retry 3 0 false' "$ROOT_DIR/scripts/lib/common.sh"
verifie_contient 'Tentative 2/3' 'retry réessaie bien 3 fois'

# Une commande qui rate une fois puis marche : retry doit finir en succès.
verifie_code 0 'retry réussit si la commande finit par passer' \
  bash -c '
    source "$0"
    compteur="$1"
    essai() { if [[ -f "$compteur" ]]; then return 0; fi; touch "$compteur"; return 1; }
    retry 3 0 essai
  ' "$ROOT_DIR/scripts/lib/common.sh" "$WORK_DIR/compteur"

# ==========================================================================
# ci/check_coverage.py
# ==========================================================================
titre 'ci/check_coverage.py'

verifie_code 0 'couverture 75% au-dessus du seuil 70 -> succès' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$FIXTURES_DIR/jacoco-ok.xml" --min 70
verifie_contient '75.00%' 'le pourcentage calculé est affiché'

verifie_code 2 'couverture 75% sous le seuil 90 -> échec de qualité (2)' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$FIXTURES_DIR/jacoco-ok.xml" --min 90

verifie_code 0 'seuil exactement atteint (75 = 75) -> succès' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$FIXTURES_DIR/jacoco-ok.xml" --min 75

verifie_code 0 'le compteur INSTRUCTION est bien pris en compte' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$FIXTURES_DIR/jacoco-ok.xml" --counter INSTRUCTION --min 85

verifie_code 1 'rapport introuvable -> erreur technique (1)' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$WORK_DIR/nexiste-pas.xml" --min 70

verifie_code 1 'rapport XML cassé -> erreur technique (1)' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$FIXTURES_DIR/jacoco-invalide.xml" --min 70

verifie_code 1 'compteur absent du rapport -> erreur technique (1)' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$FIXTURES_DIR/jacoco-ok.xml" --counter BRANCH

verifie_code 1 'compteur vide -> erreur, pas de division par zéro' \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py" --report "$FIXTURES_DIR/jacoco-vide.xml" --min 70

verifie_code 2 "argument --report manquant -> erreur d'usage argparse" \
  python3 "$ROOT_DIR/scripts/ci/check_coverage.py"

# ==========================================================================
# ci/quality_gate.py
# ==========================================================================
titre 'ci/quality_gate.py'

verifie_code 1 'SONAR_TOKEN absent -> erreur technique (1)' \
  env -u SONAR_TOKEN python3 "$ROOT_DIR/scripts/ci/quality_gate.py" --project-key projet-test
verifie_contient 'SONAR_TOKEN' 'le message dit quelle variable manque'

verifie_code 1 'SONAR_TOKEN vide -> erreur technique (1)' \
  env SONAR_TOKEN='   ' python3 "$ROOT_DIR/scripts/ci/quality_gate.py" --project-key projet-test

# On pointe vers un hôte qui ne répond pas, avec un délai très court : le script
# doit s'arrêter proprement en erreur au lieu de rester bloqué.
verifie_code 1 'hôte Sonar injoignable -> erreur technique, pas de blocage' \
  env SONAR_TOKEN='faux-token' python3 "$ROOT_DIR/scripts/ci/quality_gate.py" \
  --project-key projet-test --host 'http://127.0.0.1:9' --timeout 2 --poll 1

verifie_code 2 "argument --project-key manquant -> erreur d'usage argparse" \
  env SONAR_TOKEN='faux-token' python3 "$ROOT_DIR/scripts/ci/quality_gate.py"

# ==========================================================================
# ci/build_and_push.sh
# ==========================================================================
titre 'ci/build_and_push.sh'

# Un faux dossier à builder, avec un Dockerfile bidon.
contexte="$WORK_DIR/contexte"
mkdir -p "$contexte"
echo 'FROM scratch' >"$contexte/Dockerfile"

verifie_code 1 'sans paramètre -> erreur de configuration (1)' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh"
verifie_contient '--context' 'le message dit quel paramètre manque'

verifie_code 1 'option inconnue -> erreur de configuration (1)' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" --option-bidon

verifie_code 1 'dossier de build introuvable -> erreur (1)' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$WORK_DIR/nexiste-pas" -i img -t v1

verifie_code 1 'Dockerfile introuvable -> erreur (1)' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$contexte" -i img -t v1 -f "$WORK_DIR/pas-de-dockerfile"

verifie_code 1 'identifiants du registry manquants -> erreur (1)' \
  env -u REGISTRY_HOST -u REGISTRY_USER -u REGISTRY_PASSWORD \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$contexte" -i img -t v1

# L'aide doit afficher le mode d'emploi, et surtout pas le code du script.
verifie_code 0 '--help fonctionne' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" --help
verifie_contient '--moving-tag' "l'aide liste bien les options"
verifie_contient_pas 'source "$(cd' "l'aide ne laisse pas fuiter le code source"

journal="$(nouveau_journal docker)"
verifie_code 0 'cas nominal : login + build + push des 2 tags' \
  env FAKE_DOCKER_LOG="$journal" \
  REGISTRY_HOST='registry.test' REGISTRY_USER='ci' REGISTRY_PASSWORD='secret-bidon' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$contexte" -i 'registry.test/app' -t 'abc1234'
verifie_fichier_contient "$journal" '--password-stdin' 'le mot de passe passe par stdin (jamais en argument)'
verifie_fichier_contient "$journal" 'push registry.test/app:abc1234' 'le tag immuable (SHA) est poussé'
verifie_fichier_contient "$journal" 'push registry.test/app:latest' 'le tag mobile est poussé'
verifie_contient_pas 'secret-bidon' "le mot de passe n'apparaît pas dans les logs"

journal="$(nouveau_journal docker)"
verifie_code 1 'échec du docker login -> erreur (1), pas de build' \
  env FAKE_DOCKER_LOG="$journal" FAKE_DOCKER_LOGIN_FAIL=1 \
  REGISTRY_HOST='registry.test' REGISTRY_USER='ci' REGISTRY_PASSWORD='secret-bidon' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$contexte" -i 'registry.test/app' -t 'abc1234'
verifie_fichier_contient_pas "$journal" 'build' 'on ne build pas si le login a raté'

journal="$(nouveau_journal docker)"
verifie_code 1 'échec du docker build -> erreur (1), pas de push' \
  env FAKE_DOCKER_LOG="$journal" FAKE_DOCKER_BUILD_FAIL=1 \
  REGISTRY_HOST='registry.test' REGISTRY_USER='ci' REGISTRY_PASSWORD='secret-bidon' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$contexte" -i 'registry.test/app' -t 'abc1234'
verifie_fichier_contient_pas "$journal" 'push' "on ne pousse pas une image qui n'a pas été construite"

journal="$(nouveau_journal docker)"
verifie_code 2 '--scan : image vulnérable -> code 2 et push annulé' \
  env FAKE_DOCKER_LOG="$journal" FAKE_TRIVY_FAIL=1 \
  REGISTRY_HOST='registry.test' REGISTRY_USER='ci' REGISTRY_PASSWORD='secret-bidon' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$contexte" -i 'registry.test/app' -t 'abc1234' --scan
verifie_fichier_contient_pas "$journal" 'push' "aucune image vulnérable n'est envoyée au registry"

journal="$(nouveau_journal docker)"
verifie_code 0 '--scan : image saine -> le push a bien lieu' \
  env FAKE_DOCKER_LOG="$journal" \
  REGISTRY_HOST='registry.test' REGISTRY_USER='ci' REGISTRY_PASSWORD='secret-bidon' \
  bash "$ROOT_DIR/scripts/ci/build_and_push.sh" -c "$contexte" -i 'registry.test/app' -t 'abc1234' --scan
verifie_fichier_contient "$journal" 'push registry.test/app:abc1234' 'le push est fait après un scan sans faille'

# ==========================================================================
# deploy/deploy.sh
# ==========================================================================
titre 'deploy/deploy.sh'

verifie_code 1 'sans paramètre -> erreur de configuration (1)' \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh"

verifie_code 1 'KUBECONFIG manquant -> erreur de configuration (1)' \
  env -u KUBECONFIG bash "$ROOT_DIR/scripts/deploy/deploy.sh" -n staging -d back -c back -i img:v1

verifie_code 0 '--help fonctionne' \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh" --help
verifie_contient_pas 'source "$(cd' "l'aide ne laisse pas fuiter le code source"

journal="$(nouveau_journal kubectl)"
verifie_code 1 'deployment inexistant -> erreur avant toute modification' \
  env FAKE_KUBECTL_LOG="$journal" FAKE_DEPLOYMENT_MISSING=1 KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh" -n staging -d back -c back -i img:v1
verifie_fichier_contient_pas "$journal" 'set image' 'on ne touche pas au cluster si le deployment est absent'

journal="$(nouveau_journal kubectl)"
verifie_code 0 'déploiement qui se passe bien -> succès (0)' \
  env FAKE_KUBECTL_LOG="$journal" KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh" -n staging -d back -c back -i 'registry.test/app:abc1234'
verifie_fichier_contient "$journal" 'set image deployment/back back=registry.test/app:abc1234' \
  'la bonne image est appliquée au bon conteneur'
verifie_fichier_contient "$journal" 'rollout status' 'on attend bien la fin du déploiement'
verifie_fichier_contient_pas "$journal" 'rollout undo' 'pas de rollback quand tout va bien'

journal="$(nouveau_journal kubectl)"
verifie_code 3 'déploiement qui rate -> code 3' \
  env FAKE_KUBECTL_LOG="$journal" FAKE_ROLLOUT_FAIL=1 KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh" -n production -d back -c back -i img:v1
verifie_fichier_contient "$journal" 'rollout undo deployment/back' \
  'le rollback automatique est bien déclenché'

journal="$(nouveau_journal kubectl)"
verifie_code 3 '--no-auto-rollback : échec sans retour arrière' \
  env FAKE_KUBECTL_LOG="$journal" FAKE_ROLLOUT_FAIL=1 KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh" -n production -d back -c back -i img:v1 --no-auto-rollback
verifie_fichier_contient_pas "$journal" 'rollout undo' "l'option désactive bien le rollback automatique"

journal="$(nouveau_journal kubectl)"
verifie_code 3 "déploiement raté ET rollback raté -> code 3 + message d'alerte" \
  env FAKE_KUBECTL_LOG="$journal" FAKE_ROLLOUT_FAIL=1 FAKE_UNDO_FAIL=1 KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh" -n production -d back -c back -i img:v1
verifie_contient 'intervention manuelle' "on prévient qu'il faut intervenir à la main"

journal="$(nouveau_journal kubectl)"
verifie_code 0 '--timeout personnalisé transmis à kubectl' \
  env FAKE_KUBECTL_LOG="$journal" KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/deploy.sh" -n staging -d back -c back -i img:v1 -t 60s
verifie_fichier_contient "$journal" '--timeout=60s' 'le timeout demandé est bien utilisé'

# ==========================================================================
# deploy/rollback.sh
# ==========================================================================
titre 'deploy/rollback.sh'

verifie_code 1 'sans paramètre -> erreur de configuration (1)' \
  bash "$ROOT_DIR/scripts/deploy/rollback.sh"

verifie_code 1 'KUBECONFIG manquant -> erreur de configuration (1)' \
  env -u KUBECONFIG bash "$ROOT_DIR/scripts/deploy/rollback.sh" -n production -d back

journal="$(nouveau_journal kubectl)"
verifie_code 0 'rollback vers la version précédente -> succès (0)' \
  env FAKE_KUBECTL_LOG="$journal" KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/rollback.sh" -n production -d back
verifie_fichier_contient "$journal" 'rollout undo deployment/back' 'la commande de rollback est lancée'
verifie_fichier_contient_pas "$journal" '--to-revision' "sans option, on revient simplement à la version d'avant"

journal="$(nouveau_journal kubectl)"
verifie_code 0 'rollback vers une révision précise' \
  env FAKE_KUBECTL_LOG="$journal" KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/rollback.sh" -n production -d back --to-revision 7
verifie_fichier_contient "$journal" '--to-revision=7' 'la révision demandée est bien transmise'

journal="$(nouveau_journal kubectl)"
verifie_code 3 "rollback qui n'aboutit pas -> code 3" \
  env FAKE_KUBECTL_LOG="$journal" FAKE_ROLLOUT_FAIL=1 KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/rollback.sh" -n production -d back
verifie_contient 'intervention manuelle' "on prévient qu'il faut intervenir à la main"

journal="$(nouveau_journal kubectl)"
verifie_code 1 'deployment inexistant -> erreur avant toute action' \
  env FAKE_KUBECTL_LOG="$journal" FAKE_DEPLOYMENT_MISSING=1 KUBECONFIG="$WORK_DIR/kube.cfg" \
  bash "$ROOT_DIR/scripts/deploy/rollback.sh" -n production -d back
verifie_fichier_contient_pas "$journal" 'rollout undo' 'aucun rollback lancé sur un deployment absent'

# ==========================================================================
# Bilan
# ==========================================================================
printf '\n---------------------------------------------\n'
printf 'Résultat : %d test(s) OK, %d en échec\n' "$nb_ok" "$nb_ko"

if ((nb_ko > 0)); then
  exit 1
fi
exit 0
