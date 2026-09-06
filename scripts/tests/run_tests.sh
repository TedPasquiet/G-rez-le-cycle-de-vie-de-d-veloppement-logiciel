#!/usr/bin/env bash
#
# run_tests.sh
#
# Ce script teste les autres scripts du dossier `scripts/`. C'est le point de
# vigilance "tester chaque script dans un environnement contrôlé" : au lieu de
# le faire à la main, la CI le fait à chaque commit (job `test-scripts`).
#
# Comment ça marche :
#   Rien n'est réellement construit, déployé ni mis sous charge. Je remplace
#   `kubectl`, `docker`, `trivy` et `k6` par de faux programmes (dossier
#   `stubs/`) que je mets en premier
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
# tests/run_k6.sh
# ==========================================================================
# On ne lance évidemment pas de vrai test de charge ici : le faux k6 permet de
# vérifier que le script choisit le bon scénario, transmet bien l'URL, et
# traduit correctement les codes de sortie de k6 (99 = seuils dépassés,
# 107 = plantage). Les scénarios eux-mêmes sont joués par le job `k6-smoke`
# de la CI, contre l'application réellement démarrée.
titre 'tests/run_k6.sh'

rapports="$WORK_DIR/rapports-k6"

verifie_code 1 "scénario inconnu -> erreur de configuration (1)" \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" --scenario inexistant
verifie_contient 'smoke' "le message rappelle les scénarios disponibles"

verifie_code 1 'option inconnue -> erreur de configuration (1)' \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" --option-bidon

verifie_code 0 '--help fonctionne' \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" --help
verifie_contient '--scenario' "l'aide liste bien les options"
verifie_contient_pas 'source "$(cd' "l'aide ne laisse pas fuiter le code source"

journal="$(nouveau_journal k6)"
verifie_code 0 'cas nominal : le scénario smoke est lancé' \
  env FAKE_K6_LOG="$journal" \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" --scenario smoke --output-dir "$rapports"
verifie_fichier_contient "$journal" 'tests/k6/smoke.js' 'le bon fichier de scénario est joué'
verifie_fichier_contient "$journal" '--summary-export' 'un rapport JSON est demandé à k6'

journal="$(nouveau_journal k6)"
verifie_code 0 "--url est transmis au scénario via K6_BASE_URL" \
  env FAKE_K6_LOG="$journal" \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" -s load -u 'http://back:8080' -o "$rapports"
verifie_fichier_contient "$journal" 'K6_BASE_URL=http://back:8080' "l'URL demandée arrive bien au test"
verifie_fichier_contient "$journal" 'tests/k6/load.js' 'le scénario load est reconnu'

journal="$(nouveau_journal k6)"
verifie_code 0 'le scénario stress est reconnu' \
  env FAKE_K6_LOG="$journal" \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" -s stress --no-report
verifie_fichier_contient "$journal" 'tests/k6/stress.js' 'le bon fichier de scénario est joué'
verifie_fichier_contient_pas "$journal" '--summary-export' "--no-report n'écrit aucun rapport"

journal="$(nouveau_journal k6)"
verifie_code 0 'les options après -- sont passées telles quelles à k6' \
  env FAKE_K6_LOG="$journal" \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" -s smoke --no-report -- --vus 20 --duration 30s
verifie_fichier_contient "$journal" '--vus 20 --duration 30s' 'les options supplémentaires sont transmises'

journal="$(nouveau_journal k6)"
verifie_code 2 'seuils de performance dépassés -> code 2' \
  env FAKE_K6_LOG="$journal" FAKE_K6_THRESHOLD_FAIL=1 \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" -s load --no-report
verifie_contient 'seuils de performance' "le message explique que c'est un problème de performance"

journal="$(nouveau_journal k6)"
verifie_code 3 'k6 en erreur (API injoignable) -> code 3' \
  env FAKE_K6_LOG="$journal" FAKE_K6_FAIL=1 \
  bash "$ROOT_DIR/scripts/tests/run_k6.sh" -s smoke --no-report
verifie_contient 'injoignable' "on distingue bien la panne du dépassement de seuil"

# ==========================================================================
# ci/terraform_check.sh
# ==========================================================================
# Ce script est ce que jouent les jobs `terraform-validate`, `terraform-plan` et
# `terraform-apply`. Il est testé ici avec un faux `terraform` : sans cluster,
# sans registre de providers, et sans risquer d'écrire dans un état réel.
#
# Les cas qui comptent ne sont pas les cas nominaux mais les chemins d'échec —
# un environnement qui tombe alors que l'autre passe, et surtout le garde-fou
# qui interdit un `apply` non nommé.
titre 'ci/terraform_check.sh'

envs="$WORK_DIR/tf-envs"
mkdir -p "$envs/staging" "$envs/production"

verifie_code 0 '--help fonctionne' \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --help
verifie_contient '--apply' "l'aide mentionne le mode apply"
verifie_contient_pas 'source "$(cd' "l'aide ne laisse pas fuiter le code source"

verifie_code 1 'option inconnue -> erreur de configuration (1)' \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --option-bidon

verifie_code 1 "répertoire d'environnements inexistant -> échec explicite" \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" -d "$WORK_DIR/nexiste-pas"

vide="$WORK_DIR/tf-vide"
mkdir -p "$vide"
verifie_code 1 "répertoire sans aucun environnement -> échec" \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" -d "$vide"
verifie_contient 'Aucun environnement' "le message dit ce qui manque"

journal="$(nouveau_journal terraform)"
verifie_code 0 'cas nominal : validate passe sur les deux environnements' \
  env FAKE_TERRAFORM_LOG="$journal" \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --validate -d "$envs"
verifie_fichier_contient "$journal" 'fmt -check -recursive' 'la mise en forme est contrôlée'
verifie_fichier_contient "$journal" 'init -backend=false' "l'init ne touche pas au backend en mode validate"
verifie_fichier_contient "$journal" 'validate' 'la configuration est validée'

# `terraform fmt -check` sort en 3, pas en 1. Un script qui testerait l'égalité
# à 1 prendrait ce défaut pour un succès : c'est exactement ce que ce test
# interdit de réintroduire.
journal="$(nouveau_journal terraform)"
verifie_code 1 'un fmt en échec (code 3) fait échouer le script' \
  env FAKE_TERRAFORM_LOG="$journal" FAKE_TF_FMT_FAIL=3 \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --validate -d "$envs"
verifie_contient 'terraform fmt -recursive' "le message donne la commande qui corrige"

journal="$(nouveau_journal terraform)"
verifie_code 1 'un validate en échec fait échouer le script' \
  env FAKE_TERRAFORM_LOG="$journal" FAKE_TF_VALIDATE_FAIL=1 \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --validate -d "$envs"

# Le point le plus utile de la série : un environnement en échec ne doit pas
# empêcher l'autre d'être traité, sinon il faut deux exécutions pour voir deux
# erreurs.
journal="$(nouveau_journal terraform)"
verifie_code 1 'staging en échec : production est quand même traité' \
  env FAKE_TERRAFORM_LOG="$journal" FAKE_TF_VALIDATE_FAIL=1 FAKE_TF_FAIL_DIR=staging \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --validate -d "$envs"
verifie_fichier_contient "$journal" 'production' "l'autre environnement a bien été traité"

journal="$(nouveau_journal terraform)"
verifie_code 1 "un init en échec n'enchaîne pas sur validate" \
  env FAKE_TERRAFORM_LOG="$journal" FAKE_TF_INIT_FAIL=1 \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --validate -d "$envs"
verifie_contient 'Validation non jouée' "le script dit pourquoi il n'a pas validé"

journal="$(nouveau_journal terraform)"
verifie_code 0 'mode --plan : init avec backend, puis plan' \
  env FAKE_TERRAFORM_LOG="$journal" \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --plan -d "$envs"
verifie_fichier_contient "$journal" 'plan -input=false' 'le plan ne demande aucune saisie'
verifie_contient "ne dit donc RIEN de l'écart réel" \
  "le mode --plan avertit sur ce qu'il ne prouve pas"

# ⚠️ Le garde-fou qui compte : `--apply` écrit dans un vrai cluster. Sans -e, il
# s'appliquerait à TOUS les environnements, donc à la production, dans le même
# geste que le staging.
verifie_code 1 '--apply sans -e est refusé' \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --apply -d "$envs"
verifie_contient 'sans la nommer' "le refus explique pourquoi l'environnement doit être nommé"

verifie_code 1 '-e sur un environnement inexistant est refusé' \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --validate -e recette -d "$envs"
verifie_contient 'Disponibles' 'le message liste les environnements existants'

journal="$(nouveau_journal terraform)"
verifie_code 0 '--apply -e production ne touche que production' \
  env FAKE_TERRAFORM_LOG="$journal" \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --apply -e production -d "$envs"
verifie_fichier_contient "$journal" 'apply' "l'apply est bien lancé"
verifie_fichier_contient_pas "$journal" 'staging' "staging n'a pas été touché"

# L'apply est le seul mode qui écrit : son échec doit remonter, sans quoi un
# pipeline vert laisserait croire que l'infrastructure est en place.
journal="$(nouveau_journal terraform)"
verifie_code 1 'un apply en échec fait échouer le job' \
  env FAKE_TERRAFORM_LOG="$journal" FAKE_TF_APPLY_FAIL=1 \
  bash "$ROOT_DIR/scripts/ci/terraform_check.sh" --apply -e production -d "$envs"

# ==========================================================================
# ci/ansible_check.sh
# ==========================================================================
# Joué par le job `ansible-lint`. Le piège que ce script existe pour encoder :
# `ansible/ansible.cfg` n'est lu que si le répertoire courant est `ansible/`.
# Lancé depuis la racine, tout tourne sans inventaire et sans configuration,
# en silence. Les stubs journalisent leur PWD, ce qui permet de le vérifier.
titre 'ci/ansible_check.sh'

verifie_code 0 '--help fonctionne' \
  bash "$ROOT_DIR/scripts/ci/ansible_check.sh" --help
verifie_contient_pas 'source "$(cd' "l'aide ne laisse pas fuiter le code source"

verifie_code 1 'option inconnue -> erreur de configuration (1)' \
  bash "$ROOT_DIR/scripts/ci/ansible_check.sh" --option-bidon

verifie_code 1 'répertoire ansible inexistant -> échec explicite' \
  bash "$ROOT_DIR/scripts/ci/ansible_check.sh" -d "$WORK_DIR/pas-dansible"

journal="$(nouveau_journal ansible-lint)"
journal_pb="$(nouveau_journal ansible-playbook)"
verifie_code 0 'cas nominal : syntaxe puis lint' \
  env FAKE_ANSIBLE_LINT_LOG="$journal" FAKE_ANSIBLE_PLAYBOOK_LOG="$journal_pb" \
  bash "$ROOT_DIR/scripts/ci/ansible_check.sh" -d "$ROOT_DIR/ansible"
verifie_fichier_contient "$journal_pb" '--syntax-check' 'la syntaxe du playbook est contrôlée'
verifie_fichier_contient "$journal_pb" 'PWD=' 'le stub journalise son répertoire courant'
verifie_fichier_contient "$journal_pb" '/ansible' "les outils tournent bien DANS ansible/, sans quoi ansible.cfg serait ignoré"

journal="$(nouveau_journal ansible-lint)"
verifie_code 1 'un lint en échec fait échouer le script' \
  env FAKE_ANSIBLE_LINT_LOG="$journal" FAKE_ANSIBLE_LINT_FAIL=1 \
  bash "$ROOT_DIR/scripts/ci/ansible_check.sh" -d "$ROOT_DIR/ansible"

# Une erreur de syntaxe ne doit pas escamoter le lint : deux défauts doivent se
# lire en une exécution.
journal="$(nouveau_journal ansible-lint)"
journal_pb="$(nouveau_journal ansible-playbook)"
verifie_code 1 'une syntaxe en échec ne dispense pas de jouer le lint' \
  env FAKE_ANSIBLE_LINT_LOG="$journal" FAKE_ANSIBLE_PLAYBOOK_LOG="$journal_pb" \
  FAKE_ANSIBLE_PLAYBOOK_FAIL=1 \
  bash "$ROOT_DIR/scripts/ci/ansible_check.sh" -d "$ROOT_DIR/ansible"
verifie_fichier_contient "$journal" 'ansible-lint' "le lint a bien été joué malgré l'échec de syntaxe"

# ==========================================================================
# ci/collect_dora.py
# ==========================================================================
# Le collecteur interroge l'API GitLab. Il est donc testé sur des FIXTURES —
# des réponses d'API enregistrées — plutôt que contre le réseau : un test qui
# dépend d'un service tiers échoue les jours où ce service est lent, et on
# finit par ne plus le croire.
#
# Deux jeux de fixtures, et la distinction est le cœur de ces tests :
#
#   scripts/tests/fixtures/                      RÉEL. Les 44 pipelines du
#                                                projet et les jobs des 7
#                                                pipelines qui ont déclenché un
#                                                déploiement. Aucun n'a réussi.
#   scripts/tests/fixtures/dora-scenario-fabrique/  FABRIQUÉ. Contient ce que
#                                                le réel n'offre pas — des
#                                                déploiements RÉUSSIS — sans
#                                                quoi le calcul du lead time et
#                                                du MTTR ne serait jamais
#                                                emprunté par aucun test.
#
# `--days 0` partout : les fixtures sont datées, et une fenêtre glissante de 30
# jours les ferait sortir du périmètre dans un mois. Un test qui se met à
# échouer tout seul avec le temps est un test qu'on finit par désactiver.
titre 'ci/collect_dora.py'

verifie_code 0 '--help fonctionne' \
  python3 "$ROOT_DIR/scripts/ci/collect_dora.py" --help
verifie_contient '--fixtures' "l'aide mentionne le mode hors ligne"

verifie_code 1 'un répertoire de fixtures inexistant -> erreur (1)' \
  python3 "$ROOT_DIR/scripts/ci/collect_dora.py" --fixtures "$WORK_DIR/nexiste-pas"

# --- Sur les données RÉELLES : aucun déploiement n'a jamais abouti ---------
sortie_reelle="$WORK_DIR/dora-reel.json"
verifie_code 0 'collecte sur les fixtures réelles' \
  python3 "$ROOT_DIR/scripts/ci/collect_dora.py" \
  --fixtures "$TESTS_DIR/fixtures" --days 0 --output "$sortie_reelle"

# ⚠️ L'assertion qui compte le plus de toute cette série. Trois indicateurs sur
# quatre n'ont PAS de valeur sur ces données, et le collecteur doit le dire par
# un `null` explicite. S'il rendait `0`, un tableau de bord afficherait un
# délai de livraison de zéro heure — c'est-à-dire la performance parfaite, là
# où il n'y a simplement jamais eu de livraison.
verifie_fichier_contient "$sortie_reelle" '"lead_time_for_changes"' "l'indicateur de délai est présent"
verifie_fichier_contient "$sortie_reelle" '"valeur": null' "un indicateur sans donnée vaut null, pas zéro"
verifie_fichier_contient "$sortie_reelle" '"change_failure_rate"' "le taux d'échec est présent"

python3 - "$sortie_reelle" <<'PYTEST' >"$WORK_DIR/dora-reel.txt"
import json, sys
d = json.load(open(sys.argv[1]))
ind = {i["cle"]: i for i in d["indicateurs"]}
print("frequence", ind["deployment_frequency"]["valeur"])
print("leadtime", ind["lead_time_for_changes"]["valeur"])
print("mttr", ind["mean_time_to_restore"]["valeur"])
print("echec", ind["change_failure_rate"]["valeur"])
print("tentatives", ind["change_failure_rate"]["observations"])
PYTEST
verifie_fichier_contient "$WORK_DIR/dora-reel.txt" 'frequence 0.0' 'aucun déploiement réussi : fréquence à 0'
verifie_fichier_contient "$WORK_DIR/dora-reel.txt" 'leadtime None' "le délai de livraison est indéfini, pas nul"
verifie_fichier_contient "$WORK_DIR/dora-reel.txt" 'mttr None' 'le MTTR est indéfini, pas nul'
verifie_fichier_contient "$WORK_DIR/dora-reel.txt" 'echec 100.0' "le taux d'échec vaut 100 %"
verifie_fichier_contient "$WORK_DIR/dora-reel.txt" 'tentatives 7' 'les 7 tentatives réelles sont comptées'

# --- Sur les données FABRIQUÉES : le calcul est réellement emprunté --------
# Sans ce second jeu, les quatre formules ne seraient jamais exécutées : on
# testerait uniquement la capacité du collecteur à dire « je n'ai rien ».
sortie_fab="$WORK_DIR/dora-fabrique.json"
verifie_code 0 'collecte sur le scénario fabriqué' \
  python3 "$ROOT_DIR/scripts/ci/collect_dora.py" \
  --fixtures "$TESTS_DIR/fixtures/dora-scenario-fabrique" --days 0 --output "$sortie_fab"

python3 - "$sortie_fab" <<'PYTEST' >"$WORK_DIR/dora-fab.txt"
import json, sys
d = json.load(open(sys.argv[1]))
ind = {i["cle"]: i for i in d["indicateurs"]}
for cle in ("deployment_frequency", "lead_time_for_changes", "mean_time_to_restore", "change_failure_rate"):
    v = ind[cle]["valeur"]
    print(cle, "defini" if v is not None else "indefini", ind[cle]["observations"])
PYTEST
verifie_fichier_contient "$WORK_DIR/dora-fab.txt" 'lead_time_for_changes defini' 'le délai se calcule dès qu un déploiement réussit'
verifie_fichier_contient "$WORK_DIR/dora-fab.txt" 'mean_time_to_restore defini' 'le MTTR se calcule dès qu une panne est rétablie'
verifie_fichier_contient "$WORK_DIR/dora-fab.txt" 'deployment_frequency defini' 'la fréquence se calcule sur des succès'

# ==========================================================================
# Bilan
# ==========================================================================
printf '\n---------------------------------------------\n'
printf 'Résultat : %d test(s) OK, %d en échec\n' "$nb_ok" "$nb_ko"

if ((nb_ko > 0)); then
  exit 1
fi
exit 0
