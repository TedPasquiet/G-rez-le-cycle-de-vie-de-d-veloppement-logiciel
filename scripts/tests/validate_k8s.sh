#!/bin/sh
#
# validate_k8s.sh
#
# Ce script valide les manifestes Kubernetes du dossier `k8s/` SANS cluster, et
# le chart Helm de `helm/microcrm/` quand l'outillage le permet. C'est le
# pendant de `run_tests.sh` pour l'infrastructure : au lieu de tester les
# scripts, il teste ce que Kustomize et Helm produisent réellement.
#
# Pourquoi un script à part plutôt qu'une section de run_tests.sh :
#   run_tests.sh tourne dans l'image $PYTHON_IMAGE, qui n'a pas kubectl. Des
#   assertions sur les manifestes y seraient forcément désactivées, donc
#   décoratives. Ce script tourne dans le job `lint-k8s`, sur $KUBECTL_IMAGE,
#   où kubectl et son Kustomize embarqué sont disponibles.
#
# Pourquoi du sh POSIX et pas du bash :
#   $KUBECTL_IMAGE (alpine/kubectl) n'a que busybox sh. `.deploy_template`
#   installe bash parce que deploy.sh en a réellement besoin (tableaux,
#   BASH_SOURCE, [[ ]]). Ici le script est écrit de zéro : le garder en sh
#   POSIX évite un `apk add` dans un job de lint, donc évite qu'une panne de
#   miroir Alpine fasse échouer une validation qui n'a besoin de rien.
#
# Comment ça marche :
#   1. `kubectl kustomize` construit chaque overlay (aucun serveur d'API
#      requis, contrairement à `kubectl apply --dry-run=client`).
#   2. Un extracteur awk aplatit le YAML rendu en un flux de faits d'une ligne
#      chacun, de la forme :
#        Deployment/back spec.template.spec.containers.0.name = back
#      Les assertions ne relisent plus du YAML : elles filtrent ce flux. C'est
#      ce qui les rend lisibles et insensibles à l'ordre des clés.
#   3. `helm template` rend le même flux de faits pour le chart, ce qui permet
#      de lui rejouer les mêmes assertions puis de comparer les deux rendus.
#   4. Chaque assertion affiche `ok`, `ÉCHEC` ou `ignoré`, et un bilan sort en 1
#      si au moins une a échoué — mêmes conventions que run_tests.sh.
#
# Pourquoi un troisième état `ignoré` :
#   Deux jobs exécutent ce script. `lint-k8s` tourne sur $KUBECTL_IMAGE, qui n'a
#   pas helm ; `lint-helm` sur $HELM_IMAGE, qui a les deux. Compter la section
#   Helm en succès là où helm est absent serait un mensonge, la compter en échec
#   rendrait `lint-k8s` rouge sans raison. Elle est donc explicitement ignorée,
#   et le bilan le dit : un job vert ne doit pas laisser croire que tout a été
#   vérifié.
#
# Ce qui est vérifié :
#   - chaque overlay se construit ;
#   - les Deployments s'appellent $APP_BACK_NAME / $APP_FRONT_NAME et portent
#     un conteneur du même nom (contrat de scripts/deploy/deploy.sh, qui fait
#     `kubectl set image deployment/back back=...`) ;
#   - toute ConfigMap référencée par un Deployment existe dans le rendu (une
#     référence morte ne fait pas échouer `apply`, elle bloque le pod au
#     démarrage) ;
#   - les sondes visent un port réellement déclaré par leur conteneur ;
#   - chaque conteneur a runAsNonRoot=true et allowPrivilegeEscalation=false ;
#   - aucune image en `latest` ni sans tag ;
#   - chaque Deployment référence le Secret de tirage d'images attendu
#     ($REGISTRY_SECRET_NAME) : le registry est privé, et un nom qui diverge de
#     celui que crée la CI laisse les pods en ImagePullBackOff sans que `apply`
#     ne signale quoi que ce soit ;
#   - staging et production produisent des valeurs de ConfigMap différentes
#     (preuve que les patches d'overlay mordent au lieu d'être silencieux) ;
#   - le chart Helm passe les mêmes contrôles que les overlays, et surtout : son
#     rendu est IDENTIQUE à celui de l'overlay correspondant, au seul label
#     app.kubernetes.io/managed-by près. Deux descriptions de la même
#     application, c'est deux occasions de diverger ; c'est cette assertion-là
#     qui rend la divergence visible ici plutôt qu'au déploiement.
#
# Utilisation :
#   scripts/tests/validate_k8s.sh              # depuis n'importe quel dossier
#   scripts/tests/validate_k8s.sh --autotest   # + auto-test des assertions
#
# Variables d'environnement (valeurs par défaut entre parenthèses) :
#   K8S_OVERLAYS_DIR      Racine des overlays (k8s/overlays)
#   HELM_CHART_DIR        Racine du chart Helm (helm/microcrm)
#   APP_BACK_NAME         Nom attendu du Deployment/conteneur back (back)
#   APP_FRONT_NAME        Nom attendu du Deployment/conteneur front (front)
#   REGISTRY_SECRET_NAME  Nom attendu du pull secret (gitlab-registry)
#   Ce sont les mêmes que celles du .gitlab-ci.yml : le script vérifie donc le
#   contrat tel que la CI le déclare, pas une copie figée.
#
# Ce que renvoie le script :
#   0 = toutes les assertions passent · 1 = au moins une a échoué
#   Une section ignorée ne change pas le code de sortie : elle n'a rien prouvé,
#   elle n'a rien infirmé non plus.
#
# Prérequis : kubectl (Kustomize embarqué), awk, grep. Aucun cluster.
# Facultatif : helm, sans quoi la section Helm est ignorée au lieu d'échouer.

# Pas d'`errexit`, comme dans run_tests.sh : je veux le bilan complet même si
# une assertion échoue en cours de route.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

OVERLAYS_DIR="${K8S_OVERLAYS_DIR:-k8s/overlays}"
CHART_DIR="${HELM_CHART_DIR:-helm/microcrm}"
NOM_BACK="${APP_BACK_NAME:-back}"
NOM_FRONT="${APP_FRONT_NAME:-front}"
NOM_SECRET="${REGISTRY_SECRET_NAME:-gitlab-registry}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

nb_ok=0
nb_ko=0
# Compté à part de nb_ok : une section qu'on n'a pas pu jouer n'est pas une
# section réussie. Les confondre transformerait une absence d'outil en preuve.
nb_ignore=0
# Quand ce drapeau vaut 1, `ok` et `ko` ne s'affichent plus et comptent dans
# des compteurs séparés : c'est ce qui permet à --autotest de vérifier qu'une
# assertion échoue bien, sans polluer le bilan réel.
silencieux=0
nb_ok_sim=0
nb_ko_sim=0

# --------------------------------------------------------------------------
# Petites fonctions d'assertion (mêmes noms et même style que run_tests.sh)
# --------------------------------------------------------------------------

titre() { printf '\n== %s\n' "$1"; }

ok() {
  if [ "$silencieux" -eq 1 ]; then
    nb_ok_sim=$((nb_ok_sim + 1))
    return 0
  fi
  printf '   ok    %s\n' "$1"
  nb_ok=$((nb_ok + 1))
}

ko() {
  if [ "$silencieux" -eq 1 ]; then
    nb_ko_sim=$((nb_ko_sim + 1))
    return 0
  fi
  printf '   ÉCHEC %s\n         -> %s\n' "$1" "$2"
  nb_ko=$((nb_ko + 1))
}

# ignore_section <description> <raison>
# Ni ok ni ko : la raison est toujours affichée, parce qu'une section muette
# ignorée est indiscernable d'une section absente.
ignore_section() {
  printf '   ignoré %s\n         -> %s\n' "$1" "$2"
  nb_ignore=$((nb_ignore + 1))
}

# verifie_egal <attendu> <obtenu> <description>
verifie_egal() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    ko "$3" "attendu '$1', obtenu '$2'"
  fi
}

# verifie_different <valeur a> <valeur b> <description>
verifie_different() {
  if [ "$1" != "$2" ]; then
    ok "$3"
  else
    ko "$3" "les deux valeurs sont identiques ('$1') alors qu'elles devraient différer"
  fi
}

# --------------------------------------------------------------------------
# Extracteur : YAML rendu -> flux de faits « Kind/nom chemin = valeur »
#
# Le rendu de Kustomize est normalisé (indentation de 2, style bloc, clés
# triées), ce qui rend un aplatissement par indentation fiable. On maintient
# une pile de niveaux ; un tiret incrémente l'index de la liste courante, et
# le chemin porte cet index (containers.0.name plutôt que containers.name).
#
# Les faits d'un document sont mis en tampon puis préfixés à la fin de
# celui-ci : `kind` et `metadata.name` n'arrivent pas forcément avant les
# autres clés (pour une ConfigMap, `data` précède `kind`).
# --------------------------------------------------------------------------
aplatis() {
  awk '
    function chemin(   l, p) {
      p = ""
      for (l = 1; l <= prof; l++) {
        p = (p == "" ? ncle[l] : p "." ncle[l])
        if (nidx[l] >= 0) p = p "." nidx[l]
      }
      return p
    }
    function ajoute(c, v) { nfaits++; faits[nfaits] = c " = " v }
    function vide_doc(   i, prefixe) {
      prefixe = (kind == "" ? "?" : kind) "/" (nom == "" ? "?" : nom)
      for (i = 1; i <= nfaits; i++) print prefixe " " faits[i]
      nfaits = 0; prof = 0; kind = ""; nom = ""
    }
    BEGIN { prof = 0; nfaits = 0; kind = ""; nom = "" }
    /^---[[:space:]]*$/ { vide_doc(); next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      ligne = $0
      # Indentation, puis éventuel tiret de liste.
      ind = 0
      while (substr(ligne, ind + 1, 1) == " ") ind++
      reste = substr(ligne, ind + 1)

      if (substr(reste, 1, 2) == "- " || reste == "-") {
        # Un élément de liste est indenté comme la clé qui le porte.
        while (prof > 0 && nind[prof] >= ind + 2) prof--
        if (prof > 0) nidx[prof] = nidx[prof] + 1
        reste = (reste == "-" ? "" : substr(reste, 3))
        ind = ind + 2
        if (reste == "") next
      }

      if (reste ~ /^[A-Za-z0-9_.\/-]+:([[:space:]]|$)/) {
        # Ligne « clé: valeur » (valeur éventuellement vide).
        pos = index(reste, ":")
        cle = substr(reste, 1, pos - 1)
        val = substr(reste, pos + 1)
        sub(/^[[:space:]]+/, "", val)
        sub(/[[:space:]]+$/, "", val)
        gsub(/^["'"'"']|["'"'"']$/, "", val)

        while (prof > 0 && nind[prof] >= ind) prof--
        prof++
        nind[prof] = ind; ncle[prof] = cle; nidx[prof] = -1

        if (prof == 1 && cle == "kind") kind = val
        if (prof == 2 && ncle[1] == "metadata" && cle == "name") nom = val
        if (val != "") ajoute(chemin(), val)
      } else {
        # Élément scalaire de liste (ex. capabilities.drop.0 = ALL).
        sub(/^[[:space:]]+/, "", reste)
        sub(/[[:space:]]+$/, "", reste)
        if (reste != "") ajoute(chemin(), reste)
      }
    }
    END { vide_doc() }
  ' "$1"
}

# --------------------------------------------------------------------------
# Contrôles appliqués à un fichier de faits.
#
# Regroupés dans une fonction pour deux raisons : les rejouer sur chaque
# overlay, et pouvoir les rejouer sur un rendu volontairement abîmé (mode
# --autotest) afin de prouver qu'ils détectent bien un défaut.
#
# controles_rendu <fichier de faits> <étiquette>
# --------------------------------------------------------------------------
controles_rendu() {
  cr_faits="$1"
  cr_libelle="$2"

  # --- Contrat de nommage avec deploy.sh --------------------------------
  # deploy.sh exécute `kubectl set image deployment/<nom> <conteneur>=<image>`.
  # Le Deployment ET le conteneur doivent donc porter le nom attendu. Un
  # namePrefix Kustomize casse le premier ; un renommage de conteneur dans la
  # base casse le second, et aucun des deux ne lève d'erreur au `apply`.
  for cr_attendu in "$NOM_BACK" "$NOM_FRONT"; do
    if grep -q "^Deployment/$cr_attendu " "$cr_faits"; then
      ok "$cr_libelle : le Deployment '$cr_attendu' est produit"
    else
      ko "$cr_libelle : le Deployment '$cr_attendu' est produit" \
        "Deployments trouvés : $(sed -n 's|^Deployment/\([^ ]*\) .*|\1|p' "$cr_faits" | sort -u | tr '\n' ' ')"
    fi

    if grep -q "^Deployment/$cr_attendu spec\.template\.spec\.containers\.[0-9]*\.name = $cr_attendu\$" "$cr_faits"; then
      ok "$cr_libelle : '$cr_attendu' porte un conteneur nommé '$cr_attendu'"
    else
      ko "$cr_libelle : '$cr_attendu' porte un conteneur nommé '$cr_attendu'" \
        "conteneurs trouvés : $(sed -n "s|^Deployment/$cr_attendu spec\.template\.spec\.containers\.[0-9]*\.name = ||p" "$cr_faits" | tr '\n' ' ')"
    fi
  done

  # --- ConfigMaps référencées ------------------------------------------
  # Une référence à une ConfigMap absente ne fait pas échouer `kubectl apply` :
  # le pod reste bloqué en CreateContainerConfigError. C'est typiquement le
  # genre de défaut qu'un rendu réussi ne révèle pas.
  sed -n 's|^Deployment/\([^ ]*\) .*\.configMapRef\.name = \(.*\)$|\1 \2|p' "$cr_faits" \
    | sort -u >"$WORK_DIR/refs.txt"
  if [ ! -s "$WORK_DIR/refs.txt" ]; then
    ok "$cr_libelle : aucune ConfigMap référencée (rien à vérifier)"
  else
    while read -r cr_deploy cr_cm; do
      [ -n "${cr_cm:-}" ] || continue
      if grep -q "^ConfigMap/$cr_cm " "$cr_faits"; then
        ok "$cr_libelle : la ConfigMap '$cr_cm' référencée par '$cr_deploy' existe"
      else
        ko "$cr_libelle : la ConfigMap '$cr_cm' référencée par '$cr_deploy' existe" \
          "aucune ConfigMap de ce nom dans le rendu — le pod resterait bloqué au démarrage"
      fi
    done <"$WORK_DIR/refs.txt"
  fi

  # --- Sondes visant un port déclaré ------------------------------------
  # Une sonde qui vise un port non déclaré échoue en permanence : le pod ne
  # devient jamais Ready, ou boucle en CrashLoopBackOff pour la liveness.
  sed -n 's|^Deployment/\([^ ]*\) spec\.template\.spec\.containers\.\([0-9]*\)\.\([a-zA-Z]*Probe\)\.httpGet\.port = \(.*\)$|\1 \2 \3 \4|p' \
    "$cr_faits" >"$WORK_DIR/sondes.txt"
  if [ ! -s "$WORK_DIR/sondes.txt" ]; then
    ko "$cr_libelle : les sondes visent un port déclaré" "aucune sonde httpGet trouvée dans le rendu"
  else
    while read -r cr_deploy cr_idx cr_sonde cr_port; do
      [ -n "${cr_port:-}" ] || continue
      # Un port de sonde est soit un nom déclaré dans ports[].name, soit un
      # numéro déclaré dans ports[].containerPort.
      if grep -q "^Deployment/$cr_deploy spec\.template\.spec\.containers\.$cr_idx\.ports\.[0-9]*\.name = $cr_port\$" "$cr_faits" ||
        grep -q "^Deployment/$cr_deploy spec\.template\.spec\.containers\.$cr_idx\.ports\.[0-9]*\.containerPort = $cr_port\$" "$cr_faits"; then
        ok "$cr_libelle : $cr_deploy/$cr_sonde vise le port '$cr_port', déclaré par le conteneur"
      else
        ko "$cr_libelle : $cr_deploy/$cr_sonde vise le port '$cr_port', déclaré par le conteneur" \
          "ce port n'est déclaré ni en ports[].name ni en ports[].containerPort"
      fi
    done <"$WORK_DIR/sondes.txt"
  fi

  # --- Socle de sécurité, au niveau conteneur ---------------------------
  # Volontairement contrôlé sur le conteneur et pas sur le pod : une valeur
  # posée au niveau conteneur écrase celle du pod, donc seul le niveau
  # conteneur dit ce qui s'appliquera réellement.
  sed -n 's|^Deployment/\([^ ]*\) spec\.template\.spec\.containers\.\([0-9]*\)\.name = \(.*\)$|\1 \2 \3|p' \
    "$cr_faits" >"$WORK_DIR/conteneurs.txt"
  if [ ! -s "$WORK_DIR/conteneurs.txt" ]; then
    ko "$cr_libelle : socle de sécurité des conteneurs" "aucun conteneur trouvé dans le rendu"
  else
    while read -r cr_deploy cr_idx cr_cnom; do
      [ -n "${cr_cnom:-}" ] || continue
      cr_base="^Deployment/$cr_deploy spec\.template\.spec\.containers\.$cr_idx\.securityContext"
      if grep -q "$cr_base\.runAsNonRoot = true\$" "$cr_faits"; then
        ok "$cr_libelle : $cr_deploy/$cr_cnom a runAsNonRoot=true"
      else
        ko "$cr_libelle : $cr_deploy/$cr_cnom a runAsNonRoot=true" \
          "absent ou différent de true au niveau du conteneur"
      fi
      if grep -q "$cr_base\.allowPrivilegeEscalation = false\$" "$cr_faits"; then
        ok "$cr_libelle : $cr_deploy/$cr_cnom a allowPrivilegeEscalation=false"
      else
        ko "$cr_libelle : $cr_deploy/$cr_cnom a allowPrivilegeEscalation=false" \
          "absent ou différent de false au niveau du conteneur"
      fi
    done <"$WORK_DIR/conteneurs.txt"
  fi

  # --- Images figées ----------------------------------------------------
  # Même exigence que pour les images d'outillage du pipeline : un tag mobile
  # rend le déploiement non reproductible. `latest` explicite et absence de
  # tag sont deux formes du même défaut.
  sed -n 's|^Deployment/\([^ ]*\) spec\.template\.spec\.containers\.[0-9]*\.image = \(.*\)$|\1 \2|p' \
    "$cr_faits" >"$WORK_DIR/images.txt"
  if [ ! -s "$WORK_DIR/images.txt" ]; then
    ko "$cr_libelle : les images portent un tag figé" "aucune image trouvée dans le rendu"
  else
    while read -r cr_deploy cr_image; do
      [ -n "${cr_image:-}" ] || continue
      # Le tag est ce qui suit le dernier ':', à condition qu'aucun '/' ne le
      # suive (sinon c'est le port d'un registry, ex. registry:5000/app).
      cr_tag=''
      case "$cr_image" in
        *:*) cr_suffixe="${cr_image##*:}"; case "$cr_suffixe" in */*) cr_tag='' ;; *) cr_tag="$cr_suffixe" ;; esac ;;
      esac
      if [ -z "$cr_tag" ]; then
        ko "$cr_libelle : l'image de '$cr_deploy' porte un tag figé" \
          "'$cr_image' n'a pas de tag — Kubernetes tirerait ':latest'"
      elif [ "$cr_tag" = 'latest' ]; then
        ko "$cr_libelle : l'image de '$cr_deploy' porte un tag figé" \
          "'$cr_image' utilise le tag mobile 'latest'"
      else
        ok "$cr_libelle : l'image de '$cr_deploy' porte un tag figé ($cr_tag)"
      fi
    done <"$WORK_DIR/images.txt"
  fi

  # --- Secret de tirage d'images ----------------------------------------
  # Le registry est privé : sans imagePullSecrets, tous les pods restent en
  # ImagePullBackOff sur un cluster vierge. Le nom référencé doit être celui que
  # la CI crée ($REGISTRY_SECRET_NAME) — si les deux divergent, le Secret existe
  # mais aucun pod ne le trouve, et `apply` ne signale rien.
  while read -r cr_deploy cr_idx cr_cnom; do
    [ -n "${cr_cnom:-}" ] || continue
    case "$cr_idx" in 0) ;; *) continue ;; esac
    if grep -q "^Deployment/$cr_deploy spec\.template\.spec\.imagePullSecrets\.[0-9]*\.name = $NOM_SECRET\$" "$cr_faits"; then
      ok "$cr_libelle : $cr_deploy référence le pull secret '$NOM_SECRET'"
    else
      ko "$cr_libelle : $cr_deploy référence le pull secret '$NOM_SECRET'" \
        "trouvé : $(sed -n "s|^Deployment/$cr_deploy spec\.template\.spec\.imagePullSecrets\.[0-9]*\.name = ||p" "$cr_faits" | tr '\n' ' ')(rien = pods en ImagePullBackOff)"
    fi
  done <"$WORK_DIR/conteneurs.txt"

  # --- Hôtes d'Ingress surchargés ---------------------------------------
  # La base ne porte que des hôtes en `.invalid`, dont la RFC 2606 garantit la
  # non-résolution. C'est ce qui rend le patch de chaque overlay réellement
  # actif : si la base portait les hôtes d'un environnement réel, le patch de
  # cet environnement serait un no-op, et modifier la base changerait cet
  # environnement sans qu'aucun overlay ne le montre. Un `.invalid` qui survit
  # au rendu signale donc un patch d'Ingress oublié ou qui ne mord pas.
  cr_invalides="$(sed -n 's|^Ingress/[^ ]* spec\.rules\.[0-9]*\.host = ||p' "$cr_faits" \
    | grep -c '\.invalid$' || true)"
  if [ "${cr_invalides:-0}" -eq 0 ]; then
    ok "$cr_libelle : tous les hôtes d'Ingress sont surchargés par l'overlay"
  else
    ko "$cr_libelle : tous les hôtes d'Ingress sont surchargés par l'overlay" \
      "$cr_invalides hôte(s) en '.invalid' subsistent — le patch d'Ingress ne mord pas"
  fi
}

# --------------------------------------------------------------------------
# Équivalence entre le rendu d'un overlay et celui du chart Helm.
#
# Toutes les assertions précédentes valent aussi pour le chart, mais aucune ne
# le rattache aux overlays : un chart peut satisfaire chaque contrôle un par un
# et décrire malgré tout une autre application. Une valeur oubliée dans
# values-production.yaml se rend sans erreur, passe le lint, et ne se voit qu'au
# déploiement. C'est donc cette assertion-ci, et elle seule, qui empêche le
# chart de dériver — les autres ne font que la compléter.
#
# Le label app.kubernetes.io/managed-by est écarté parce que c'est la seule
# différence légitime (`kustomize` contre `helm`) : la garder ferait échouer la
# comparaison à chaque exécution, ce qui reviendrait à la désactiver.
#
# Le tri n'est pas cosmétique : Kustomize réordonne les clés de chaque objet
# alphabétiquement, Helm rend les templates tels qu'ils sont écrits. Comparer
# sans trier ne mesurerait que cet écart de forme.
#
# compare_faits <faits Kustomize> <faits Helm> <étiquette>
# --------------------------------------------------------------------------
compare_faits() {
  cf_ref="$1"
  cf_chart="$2"
  cf_libelle="$3"

  grep -v 'app\.kubernetes\.io/managed-by = ' "$cf_ref" | sort >"$WORK_DIR/cmp-kustomize.txt"
  grep -v 'app\.kubernetes\.io/managed-by = ' "$cf_chart" | sort >"$WORK_DIR/cmp-helm.txt"

  # Le détail est produit par awk plutôt que par `diff` : awk est déjà la
  # dépendance de l'extracteur, alors que `diff` dépend de l'applet busybox de
  # l'image. Chaque ligne divergente est attribuée à son camp — c'est ce qui
  # permet de savoir quel champ a bougé, et dans quel sens, sans relancer
  # d'outil. Le comptage plutôt qu'un simple marquage de présence attrape aussi
  # le cas où une ligne existe des deux côtés mais pas le même nombre de fois.
  awk '
    NR == FNR { ref[$0]++; next }
    { chart[$0]++ }
    END {
      for (l in ref)   if (ref[l] > chart[l]) print "Kustomize seul : " l
      for (l in chart) if (chart[l] > ref[l]) print "Helm seul      : " l
    }
  ' "$WORK_DIR/cmp-kustomize.txt" "$WORK_DIR/cmp-helm.txt" | sort >"$WORK_DIR/cmp-ecarts.txt"

  cf_desc="$cf_libelle : le rendu du chart est identique à celui de l'overlay (hors managed-by)"
  if [ ! -s "$WORK_DIR/cmp-ecarts.txt" ]; then
    ok "$cf_desc"
  else
    cf_nb="$(wc -l <"$WORK_DIR/cmp-ecarts.txt" | tr -d ' ')"
    ko "$cf_desc" "$cf_nb ligne(s) de divergence, dont :
$(sed -n '1,10p' "$WORK_DIR/cmp-ecarts.txt" | sed 's|^|            |')"
  fi
}

# --------------------------------------------------------------------------
# Construction des overlays
# --------------------------------------------------------------------------
titre 'Construction des overlays'

cd "$ROOT_DIR" || exit 1

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'ERREUR : kubectl est introuvable (le job lint-k8s le fournit via son image).\n' >&2
  exit 1
fi

environnements='staging production'
for env in $environnements; do
  rendu="$WORK_DIR/rendu-$env.yaml"
  if kubectl kustomize "$OVERLAYS_DIR/$env" >"$rendu" 2>"$WORK_DIR/erreur-$env.txt"; then
    ok "l'overlay $env se construit"
  else
    ko "l'overlay $env se construit" "$(cat "$WORK_DIR/erreur-$env.txt")"
    continue
  fi
  aplatis "$rendu" >"$WORK_DIR/faits-$env.txt"
  if [ -s "$WORK_DIR/faits-$env.txt" ]; then
    ok "le rendu de $env est exploitable ($(wc -l <"$WORK_DIR/faits-$env.txt" | tr -d ' ') faits extraits)"
  else
    ko "le rendu de $env est exploitable" "l'extracteur n'a produit aucun fait"
  fi
done

# --------------------------------------------------------------------------
# Contrôles par overlay
# --------------------------------------------------------------------------
for env in $environnements; do
  [ -s "$WORK_DIR/faits-$env.txt" ] || continue
  titre "Overlay $env"
  controles_rendu "$WORK_DIR/faits-$env.txt" "$env"
done

# --------------------------------------------------------------------------
# Comparaison staging / production
#
# Un patch stratégique dont le sélecteur ne matche aucune cible est silencieux :
# le rendu réussit, la valeur d'origine reste. Le seul moyen de prouver qu'un
# patch mord est de constater la valeur patchée dans le rendu.
# --------------------------------------------------------------------------
titre 'Différences attendues entre staging et production'

if [ -s "$WORK_DIR/faits-staging.txt" ] && [ -s "$WORK_DIR/faits-production.txt" ]; then
  for cle in MICROCRM_CORS_ALLOWED_ORIGINS FRONT_API_BASE_URL; do
    val_stg="$(sed -n "s|^ConfigMap/[^ ]* data\.$cle = ||p" "$WORK_DIR/faits-staging.txt" | head -1)"
    val_prd="$(sed -n "s|^ConfigMap/[^ ]* data\.$cle = ||p" "$WORK_DIR/faits-production.txt" | head -1)"
    if [ -z "$val_stg" ] || [ -z "$val_prd" ]; then
      ko "la clé $cle est présente dans les deux overlays" \
        "staging='$val_stg' production='$val_prd'"
    else
      verifie_different "$val_stg" "$val_prd" \
        "$cle diffère entre staging et production (le patch de ConfigMap mord)"
    fi
  done

  # L'hôte de l'Ingress doit lui aussi être patché par overlay, sinon staging
  # et production répondraient sur le même nom de domaine.
  hote_stg="$(sed -n 's|^Ingress/[^ ]* spec\.rules\.0\.host = ||p' "$WORK_DIR/faits-staging.txt" | head -1)"
  hote_prd="$(sed -n 's|^Ingress/[^ ]* spec\.rules\.0\.host = ||p' "$WORK_DIR/faits-production.txt" | head -1)"
  verifie_different "$hote_stg" "$hote_prd" \
    "l'hôte de l'Ingress diffère entre staging et production (le patch d'Ingress mord)"

  # Le patch de ressources n'existe qu'en production : sans lui, la limite
  # mémoire du back resterait celle de la base.
  mem_stg="$(sed -n 's|^Deployment/'"$NOM_BACK"' spec\.template\.spec\.containers\.0\.resources\.limits\.memory = ||p' "$WORK_DIR/faits-staging.txt" | head -1)"
  mem_prd="$(sed -n 's|^Deployment/'"$NOM_BACK"' spec\.template\.spec\.containers\.0\.resources\.limits\.memory = ||p' "$WORK_DIR/faits-production.txt" | head -1)"
  verifie_different "$mem_stg" "$mem_prd" \
    "la limite mémoire du back diffère entre staging et production (le patch de ressources mord)"

  # Le back reste à 1 replica partout : HSQLDB vit dans la mémoire du
  # processus, deux pods donneraient deux jeux de données divergents.
  for env in $environnements; do
    rep="$(sed -n 's|^Deployment/'"$NOM_BACK"' spec\.replicas = ||p' "$WORK_DIR/faits-$env.txt" | head -1)"
    verifie_egal '1' "$rep" "le back reste à 1 replica en $env (base HSQLDB en mémoire)"
  done
else
  ko 'comparaison staging/production' 'un des deux rendus est absent'
fi

# --------------------------------------------------------------------------
# Rendu du chart Helm
#
# `helm template` ne contacte aucun cluster, comme `kubectl kustomize` : les
# deux rendus se construisent dans les mêmes conditions, donc se comparent.
#
# La détection d'outillage est ce qui permet au script de rester le même dans
# les deux jobs. `lint-k8s` n'a pas helm et doit rester vert ; `lint-helm` a les
# deux et doit tout jouer. Le répertoire du chart est testé en plus du binaire,
# pour que HELM_CHART_DIR mal pointé donne un message clair plutôt qu'une
# cascade d'erreurs de rendu.
# --------------------------------------------------------------------------
titre 'Rendu du chart Helm'

helm_disponible=0
if ! command -v helm >/dev/null 2>&1; then
  ignore_section 'contrôles du chart Helm' \
    "helm est introuvable — attendu sur \$HELM_IMAGE (job lint-helm), absent de \$KUBECTL_IMAGE (job lint-k8s)"
elif [ ! -d "$CHART_DIR" ]; then
  ignore_section 'contrôles du chart Helm' \
    "le chart '$CHART_DIR' est absent (variable HELM_CHART_DIR)"
else
  helm_disponible=1
  for env in $environnements; do
    valeurs="$CHART_DIR/values-$env.yaml"
    # Un fichier de valeurs manquant est un vrai défaut, pas une absence
    # d'outillage : le chart prétend couvrir cet environnement.
    if [ ! -f "$valeurs" ]; then
      ko "le chart couvre l'environnement $env" "$valeurs est absent"
      continue
    fi
    rendu_helm="$WORK_DIR/rendu-helm-$env.yaml"
    # Nom de release figé : le chart n'en dépend pas (aucun objet n'est préfixé,
    # voir helm/microcrm/templates/_helpers.tpl), mais le figer garantit que le
    # rendu comparé ne varie pas selon qui lance le script.
    if helm template microcrm "$CHART_DIR" -f "$valeurs" \
      >"$rendu_helm" 2>"$WORK_DIR/erreur-helm-$env.txt"; then
      ok "le chart se rend avec les valeurs de $env"
    else
      ko "le chart se rend avec les valeurs de $env" "$(cat "$WORK_DIR/erreur-helm-$env.txt")"
      continue
    fi
    aplatis "$rendu_helm" >"$WORK_DIR/faits-helm-$env.txt"
    if [ -s "$WORK_DIR/faits-helm-$env.txt" ]; then
      ok "le rendu Helm de $env est exploitable ($(wc -l <"$WORK_DIR/faits-helm-$env.txt" | tr -d ' ') faits extraits)"
    else
      ko "le rendu Helm de $env est exploitable" "l'extracteur n'a produit aucun fait"
    fi
  done
fi

# --------------------------------------------------------------------------
# Contrôles par rendu du chart
#
# Les mêmes assertions que pour les overlays, sans exception : le contrat de
# nommage avec deploy.sh, le socle de sécurité, les tags figés et le pull secret
# ne deviennent pas facultatifs parce que c'est Helm qui rend. L'étiquette
# préfixée `helm/` est ce qui permet de savoir, en lisant la sortie, laquelle
# des deux descriptions est fautive.
# --------------------------------------------------------------------------
if [ "$helm_disponible" -eq 1 ]; then
  for env in $environnements; do
    [ -s "$WORK_DIR/faits-helm-$env.txt" ] || continue
    titre "Chart Helm, valeurs de $env"
    controles_rendu "$WORK_DIR/faits-helm-$env.txt" "helm/$env"
  done
fi

# --------------------------------------------------------------------------
# Équivalence des deux descriptions
# --------------------------------------------------------------------------
titre 'Équivalence des rendus Kustomize et Helm'

if [ "$helm_disponible" -eq 0 ]; then
  ignore_section 'équivalence des rendus Kustomize et Helm' \
    "aucun rendu de chart n'a été produit, il n'y a rien à comparer aux overlays"
else
  for env in $environnements; do
    if [ -s "$WORK_DIR/faits-$env.txt" ] && [ -s "$WORK_DIR/faits-helm-$env.txt" ]; then
      compare_faits "$WORK_DIR/faits-$env.txt" "$WORK_DIR/faits-helm-$env.txt" "$env"
    else
      ko "$env : équivalence des rendus Kustomize et Helm" \
        'un des deux rendus est absent, la comparaison ne prouverait rien'
    fi
  done
fi

# --------------------------------------------------------------------------
# Auto-test des assertions (--autotest)
#
# Une assertion qui ne se déclenche jamais ne prouve rien. On abîme donc une
# copie des faits de staging, défaut par défaut, et on vérifie que le nombre
# d'échecs augmente. Les assertions jouées ici comptent dans des compteurs
# séparés, pour ne pas polluer le bilan réel.
# --------------------------------------------------------------------------
autotest_defaut() {
  # autotest_defaut <description> <commande sed appliquée aux faits>
  ad_desc="$1"
  ad_sed="$2"
  sed "$ad_sed" "$WORK_DIR/faits-staging.txt" >"$WORK_DIR/faits-abimes.txt"

  if cmp -s "$WORK_DIR/faits-staging.txt" "$WORK_DIR/faits-abimes.txt"; then
    ko "auto-test : $ad_desc" "le défaut n'a pas pu être injecté (les faits sont inchangés)"
    return 0
  fi

  silencieux=1
  nb_ko_sim=0
  nb_ok_sim=0
  controles_rendu "$WORK_DIR/faits-abimes.txt" 'auto-test'
  silencieux=0

  if [ "$nb_ko_sim" -gt 0 ]; then
    ok "auto-test : $ad_desc est bien détecté ($nb_ko_sim assertion(s) en échec)"
  else
    ko "auto-test : $ad_desc est bien détecté" \
      "aucune assertion n'a échoué sur un rendu pourtant abîmé — l'assertion est décorative"
  fi
}

# L'assertion d'équivalence se teste dans les DEUX sens, et le second compte
# autant que le premier : une comparaison qui refuse la seule différence
# légitime échoue à chaque exécution, se fait désactiver dans la semaine, et ne
# protège alors plus rien du tout.
#
# autotest_comparaison <description> <faits Helm simulés> <verdict attendu : ok|echec>
autotest_comparaison() {
  ac_desc="$1"
  ac_simule="$2"
  ac_attendu="$3"

  silencieux=1
  nb_ok_sim=0
  nb_ko_sim=0
  compare_faits "$WORK_DIR/faits-staging.txt" "$ac_simule" 'auto-test'
  silencieux=0

  if [ "$ac_attendu" = 'echec' ]; then
    if [ "$nb_ko_sim" -gt 0 ]; then
      ok "auto-test : $ac_desc"
    else
      ko "auto-test : $ac_desc" \
        'la comparaison a accepté deux rendus pourtant divergents — elle ne protège de rien'
    fi
  else
    if [ "$nb_ko_sim" -eq 0 ] && [ "$nb_ok_sim" -gt 0 ]; then
      ok "auto-test : $ac_desc"
    else
      ko "auto-test : $ac_desc" \
        'la comparaison a rejeté la seule différence légitime — elle serait rouge en permanence'
    fi
  fi
}

if [ "${1:-}" = '--autotest' ]; then
  titre 'Auto-test des assertions (rendus volontairement abîmés)'
  if [ -s "$WORK_DIR/faits-staging.txt" ]; then
    autotest_defaut "un namePrefix qui renomme les Deployments" \
      "s|^Deployment/|Deployment/staging-|"
    autotest_defaut "un conteneur renommé (contrat deploy.sh rompu)" \
      "s|^\(Deployment/$NOM_BACK spec\.template\.spec\.containers\.0\.name\) = $NOM_BACK\$|\1 = backend|"
    autotest_defaut "une ConfigMap référencée mais absente du rendu" \
      "s|^ConfigMap/microcrm-config |ConfigMap/autre-nom |"
    autotest_defaut "une sonde visant un port non déclaré" \
      "s|\(\.startupProbe\.httpGet\.port\) = http\$|\1 = admin|"
    autotest_defaut "un conteneur sans runAsNonRoot" \
      "/containers\.0\.securityContext\.runAsNonRoot = true\$/d"
    autotest_defaut "un conteneur avec allowPrivilegeEscalation supprimé" \
      "/containers\.0\.securityContext\.allowPrivilegeEscalation = false\$/d"
    autotest_defaut "une image en tag mobile latest" \
      "s|\(containers\.0\.image\) = .*\$|\1 = microcrm/back:latest|"
    autotest_defaut "une image sans tag" \
      "s|\(containers\.0\.image\) = .*\$|\1 = microcrm/back|"
    autotest_defaut "un imagePullSecrets absent (registry privé injoignable)" \
      "/spec\.template\.spec\.imagePullSecrets\.[0-9]*\.name = /d"
    autotest_defaut "un imagePullSecrets pointant sur un autre Secret que celui de la CI" \
      "s|\(spec\.template\.spec\.imagePullSecrets\.[0-9]*\.name\) = .*\$|\1 = autre-secret|"
  else
    ko 'auto-test' 'le rendu de staging est absent, impossible de jouer les défauts'
  fi

  titre "Auto-test de l'assertion d'équivalence"
  if [ "$helm_disponible" -eq 0 ]; then
    # Ces deux auto-tests portent sur compare_faits, qui n'a de sens que face à
    # un rendu de chart : les jouer sans helm reviendrait à tester la fonction
    # contre elle-même.
    ignore_section "auto-test de l'assertion d'équivalence" \
      "aucun rendu de chart n'a été produit, la comparaison n'a pas été jouée"
  elif [ ! -s "$WORK_DIR/faits-staging.txt" ]; then
    ko "auto-test de l'assertion d'équivalence" \
      'le rendu Kustomize de staging est absent, impossible de simuler un rendu de chart'
  else
    # Un rendu de chart plausible se fabrique à partir des faits Kustomize :
    # partir du vrai rendu Helm ferait dépendre l'auto-test de la conformité
    # actuelle du chart, alors qu'il doit valider la comparaison elle-même.
    sed 's|\(app\.kubernetes\.io/managed-by\) = kustomize$|\1 = helm|' \
      "$WORK_DIR/faits-staging.txt" >"$WORK_DIR/faits-simules.txt"
    if cmp -s "$WORK_DIR/faits-staging.txt" "$WORK_DIR/faits-simules.txt"; then
      ko "auto-test : la différence de managed-by est bien tolérée" \
        "aucun label managed-by=kustomize dans les faits — la simulation ne prouverait rien"
    else
      autotest_comparaison 'la seule différence de managed-by est tolérée' \
        "$WORK_DIR/faits-simules.txt" 'ok'
    fi

    # Une divergence réelle, du genre exact que le chart peut introduire : une
    # valeur oubliée dans un fichier de valeurs d'environnement.
    sed 's|\(containers\.0\.resources\.limits\.memory\) = .*$|\1 = 64Mi|' \
      "$WORK_DIR/faits-simules.txt" >"$WORK_DIR/faits-simules-divergents.txt"
    if cmp -s "$WORK_DIR/faits-simules.txt" "$WORK_DIR/faits-simules-divergents.txt"; then
      ko "auto-test : une divergence réelle est bien détectée" \
        "la divergence n'a pas pu être injectée (les faits sont inchangés)"
    else
      autotest_comparaison 'une divergence réelle entre les deux rendus est détectée' \
        "$WORK_DIR/faits-simules-divergents.txt" 'echec'
    fi
  fi
fi

# --------------------------------------------------------------------------
# Bilan
# --------------------------------------------------------------------------
printf '\n---------------------------------------------\n'
printf 'Résultat : %d test(s) OK, %d en échec\n' "$nb_ok" "$nb_ko"

# Sans cette ligne, un `0 en échec` laisserait croire que tout a été vérifié
# alors qu'une partie ne l'a même pas été. Le nombre n'est affiché que s'il est
# non nul : sur $HELM_IMAGE, où tout se joue, le bilan reste celui d'avant.
if [ "$nb_ignore" -gt 0 ]; then
  printf "⚠️  %d section(s) ignorée(s) faute d'outillage : non vérifiées, ni réussies ni en échec.\n" "$nb_ignore"
fi

if [ "$nb_ko" -gt 0 ]; then
  exit 1
fi
exit 0
