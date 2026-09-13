#!/usr/bin/env bash
#
# terraform_check.sh
#
# Passe les environnements Terraform du dépôt au contrôle, depuis la CI comme
# depuis un poste. C'est le pendant de scripts/tests/validate_k8s.sh pour le
# lot Terraform : la logique vit dans un script versionné plutôt que dans un
# bloc `script:` du .gitlab-ci.yml, donc elle se rejoue en local, se relit avec
# ShellCheck et se teste avec un faux `terraform` (scripts/tests/stubs/terraform).
#
# Deux modes, parce qu'ils n'ont ni le même coût ni la même valeur de preuve :
#
#   --validate (défaut)  Ne parle à AUCUN cluster et ne touche PAS à l'état.
#                        `terraform fmt -check` sur tout l'arbre, puis
#                        `init -backend=false` + `validate` pour chaque
#                        environnement. C'est le mode que la CI peut jouer sur
#                        n'importe quel runner, sans aucun accès.
#   --plan               `init` puis `plan` pour chaque environnement. Exige
#                        l'état partagé ET un cluster joignable. Enregistre le
#                        plan (`plan.cache`) et son résumé (`plan.json`).
#   --apply              `init` puis `apply`. EXIGE -e. Applique le plan
#                        ENREGISTRÉ s'il est là, sinon replanifie.
#
# ⚠️ Ce que `--plan` prouve, et ce qu'il ne prouve pas
#   Depuis la bascule sur l'état managé GitLab (TERRAFORM.md §4), le plan lit un
#   état PARTAGÉ : il compare donc le dépôt à ce qui existe réellement, et un
#   « 0 to add, 0 to change » a enfin un sens. Ça n'a pas toujours été le cas —
#   avec l'état local jamais commité, la CI repartait d'un état vide et le plan
#   annonçait « tout à créer » quel que soit le contenu du cluster.
#
#   Ce qu'un plan ne dira jamais, même partagé : si l'`apply` passera. Un
#   `Deployment` ne consomme aucun quota, seuls ses pods en consomment — un plan
#   ne peut pas trancher qu'un ResourceQuota laissera passer un déploiement
#   complet (TERRAFORM.md §9.4).
#
# Les options :
#   -d <répertoire>   Répertoire contenant un sous-répertoire par environnement.
#                     Par défaut : terraform/environments, surchargeable aussi
#                     par $TERRAFORM_ENVS_DIR.
#       --validate    Mode fmt + init -backend=false + validate (défaut).
#       --plan        Mode init + plan. Exige $TF_STATE_BASE_URL.
#       --apply       Mode init + apply. EXIGE -e et $TF_STATE_BASE_URL.
#   --require-plan    Avec --apply uniquement : refuse d'appliquer s'il n'y a pas
#                     de plan enregistré, au lieu de replanifier. C'est ce que
#                     passent les jobs de CI — voir « Le plan relu » plus bas.
#   -e <nom>          Restreint le traitement à un seul environnement.
#                     Facultatif pour --validate et --plan, OBLIGATOIRE pour
#                     --apply : appliquer en boucle sur tous les environnements
#                     ferait passer la production dans le même geste que le
#                     staging, sans que rien ne le distingue à la lecture du job.
#   -h, --help        Affiche l'aide.
#
# Variables d'environnement :
#   TERRAFORM_ENVS_DIR   Même rôle que -d ; l'option a la priorité.
#
#   TF_STATE_BASE_URL    Racine des états managés GitLab, SANS le nom de
#                        l'environnement — le script y ajoute `/<env>`, ce qui
#                        donne un état distinct et verrouillé par
#                        environnement. Obligatoire en --plan et --apply,
#                        ignorée en --validate (qui joue `init -backend=false`
#                        et ne touche donc à aucun état).
#                        En CI :
#                          $CI_API_V4_URL/projects/$CI_PROJECT_ID/terraform/state
#   TF_HTTP_USERNAME     Identifiants du backend `http`. En CI :
#   TF_HTTP_PASSWORD     `gitlab-ci-token` / $CI_JOB_TOKEN. Sur un poste : un
#                        jeton personnel de portée `api`. Jamais dans le dépôt.
#
# Les TF_HTTP_ADDRESS / LOCK_ADDRESS / UNLOCK_ADDRESS ne sont PAS à régler à la
# main : le script les compose par environnement. C'est ce qui permet de
# n'écrire nulle part l'identifiant numérique du projet GitLab.
#
# ⚠️ Le plan relu, et pourquoi `--require-plan` existe
#   Un `apply` qui replanifie n'applique pas ce qui a été relu : il applique ce
#   que le cluster et l'état disent à l'instant où il tourne. L'écart est
#   généralement mince, et c'est précisément ce qui le rend dangereux — il
#   n'apparaît nulle part. `--plan` enregistre donc son plan (`plan.cache`,
#   publié en artefact par la CI) et `--apply` applique CE fichier.
#
#   Terraform refuse un plan devenu obsolète (« Saved plan is stale ») dès que
#   l'état a bougé entre les deux. C'est le comportement recherché : mieux vaut
#   un job rouge qui demande de replanifier qu'un apply silencieusement
#   différent de ce qui a été approuvé.
#
#   Sans `--require-plan`, l'absence de plan enregistré fait replanifier avec un
#   avertissement : c'est le mode d'un poste, où personne n'a relu de plan en
#   merge request. En CI, le drapeau transforme cette absence en échec — un
#   artefact expiré ou un job relancé seul ne doit pas dégrader la garantie sans
#   le dire.
#
# Ce que renvoie le script :
#   0 = tous les contrôles passent · 1 = au moins un a échoué, ou la
#   configuration du script elle-même est invalide.
#
# Tous les environnements sont traités, même après un échec : deux erreurs se
# lisent en une exécution au lieu de deux.
#
# Exemples :
#   scripts/ci/terraform_check.sh
#   scripts/ci/terraform_check.sh --plan -d terraform/environments
#   scripts/ci/terraform_check.sh --apply -e production

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

# Noms des deux fichiers que `--plan` laisse dans le répertoire de
# l'environnement. Relatifs, parce que `-chdir=` fait de ce répertoire le
# répertoire courant de terraform. Les deux sont dans terraform/.gitignore.
#
#   plan.cache  le plan binaire, celui qu'on applique. Il embarque les valeurs
#               lues dans l'état : à traiter comme l'état lui-même.
#   plan.json   trois entiers (create/update/delete), pour le widget des merge
#               requests. Le JSON COMPLET du plan, lui, n'est jamais écrit sur
#               le disque — il ne fait que passer dans un tube vers jq.
readonly FICHIER_PLAN="plan.cache"
readonly FICHIER_RESUME="plan.json"

# Lance une commande en la nommant, et renvoie 1 si elle échoue — sans arrêter
# l'appelant, qui doit pouvoir continuer sur l'environnement suivant.
#
# Le code de sortie réel est affiché parce qu'il porte une information que « ça
# a raté » n'a pas : `terraform fmt -check` sort en 3 quand un fichier est mal
# formaté, en 1 quand il n'a pas su lire un fichier. Le script ne teste donc
# jamais l'égalité à 1, seulement « non nul » — présumer 1 ferait passer le
# défaut le plus courant pour un succès.
lance() {
  local libelle="$1"
  shift

  log_info "$libelle"
  local code=0
  "$@" || code=$?

  if ((code != 0)); then
    log_error "$libelle : échec (code de sortie $code)"
    return 1
  fi
  return 0
}

# Compose l'adresse de l'état managé GitLab pour UN environnement, et l'expose
# à terraform par les variables TF_HTTP_*.
#
# Pourquoi ici, et pas dans le bloc `backend "http"` du HCL : l'adresse porte
# l'identifiant numérique du projet GitLab. Écrite dans le dépôt, elle
# interdirait tout fork et tout déménagement de projet, et donnerait au lecteur
# l'illusion que l'état est attaché au CODE alors qu'il est attaché à
# l'INSTANCE. Le HCL ne garde donc que ce qui est vrai pour tout le monde (les
# méthodes du contrat GitLab) ; le reste arrive par l'environnement.
#
# Pourquoi un état PAR environnement, composé à partir de son nom : un état
# unique ferait de `terraform destroy` lancé dans staging une commande capable
# d'emporter la production. La séparation n'est pas une commodité, c'est le
# garde-fou.
#
# ⚠️ Ces exports sont faits DANS la boucle, avant chaque environnement. Un
# export global serait un bug silencieux : tous les environnements écriraient
# dans le même état, le dernier `apply` écrasant les précédents.
configure_etat_distant() {
  local nom="$1"
  local base="${TF_STATE_BASE_URL%/}"

  export TF_HTTP_ADDRESS="$base/$nom"
  export TF_HTTP_LOCK_ADDRESS="$base/$nom/lock"
  export TF_HTTP_UNLOCK_ADDRESS="$base/$nom/lock"

  log_info "[$nom] État : $TF_HTTP_ADDRESS"
}

# Produit le résumé du plan pour le widget des merge requests.
#
# N'échoue JAMAIS le contrôle : le plan, lui, a réussi — c'est lui qui porte la
# preuve, le résumé n'est qu'un confort de lecture. Un widget manquant se voit
# dans le journal du job (WARN) ; il ne doit pas faire passer un plan vert pour
# un échec.
resume_plan() {
  local env="$1" nom="$2"

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "[$nom] jq absent : pas de résumé pour le widget de merge request (le plan lui-même est intact)"
    return 0
  fi

  if terraform -chdir="$env" show -json "$FICHIER_PLAN" \
    | jq -r '([.resource_changes[]?.change.actions?] | flatten)
             | {"create": (map(select(. == "create")) | length),
                "update": (map(select(. == "update")) | length),
                "delete": (map(select(. == "delete")) | length)}' \
      >"$env/$FICHIER_RESUME"; then
    log_info "[$nom] Résumé du plan : $(tr -d ' \n' <"$env/$FICHIER_RESUME")"
  else
    # Un résumé tronqué serait pire que pas de résumé : le widget afficherait
    # « 0 to add » sur un plan qui en crée six.
    rm -f "$env/$FICHIER_RESUME"
    log_warn "[$nom] Résumé du plan non produit — le widget de merge request restera muet"
  fi
  return 0
}

main() {
  local envs_dir="${TERRAFORM_ENVS_DIR:-terraform/environments}"
  local mode='validate'
  local env_unique=''
  local exige_plan=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) envs_dir="${2:?}"; shift 2 ;;
      -e) env_unique="${2:?}"; shift 2 ;;
      --validate) mode='validate'; shift ;;
      --plan) mode='plan'; shift ;;
      --apply) mode='apply'; shift ;;
      --require-plan) exige_plan=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Option inconnue : '$1' (voir --help)" ;;
    esac
  done

  # ⚠️ Le garde-fou le plus important du script. `--apply` écrit dans un vrai
  # cluster ; le laisser boucler sur tous les environnements ferait appliquer la
  # production dans le même geste que le staging, et un job de CI qui fait ça ne
  # le dit nulle part dans son nom. Exiger -e oblige à écrire l'environnement
  # visé dans le pipeline, donc à le relire à chaque modification.
  if [[ "$mode" == 'apply' && -z "$env_unique" ]]; then
    die "--apply exige -e <environnement> : appliquer sur tous les environnements à la fois n'est pas une opération qu'on lance sans la nommer"
  fi

  # Un drapeau sans effet est un piège : il laisse croire à une garantie que
  # personne n'applique. Mieux vaut refuser la ligne de commande.
  if ((exige_plan)) && [[ "$mode" != 'apply' ]]; then
    die "--require-plan ne vaut qu'avec --apply (mode demandé : --$mode)"
  fi

  require_cmd terraform

  # `--validate` joue `init -backend=false` : il ne touche à aucun état, donc il
  # ne demande ni adresse ni identifiants. C'est ce qui lui permet de tourner sur
  # n'importe quel runner, y compris sur les branches de fonctionnalité. Les deux
  # autres modes, eux, LISENT l'état partagé — sans adresse, `init` échouerait
  # sur un message de backend que personne ne rattache à une variable manquante.
  # Mieux vaut le dire ici, en nommant la variable et sa valeur en CI.
  if [[ "$mode" != 'validate' ]]; then
    [[ -n "${TF_STATE_BASE_URL:-}" ]] || die "\$TF_STATE_BASE_URL est vide : le mode --$mode lit l'état partagé et a besoin de son adresse. En CI : \$CI_API_V4_URL/projects/\$CI_PROJECT_ID/terraform/state (voir TERRAFORM.md §4)"

    # Un avertissement, pas un refus : le backend `http` n'impose pas
    # d'authentification, et rien ne dit que $TF_STATE_BASE_URL pointe forcément
    # sur GitLab. Sur GitLab, en revanche, l'absence d'identifiants se traduit
    # par un 401 que ce message rend lisible d'avance.
    if [[ -z "${TF_HTTP_USERNAME:-}" && -z "${TF_HTTP_PASSWORD:-}" ]]; then
      log_warn "Aucun \$TF_HTTP_USERNAME/\$TF_HTTP_PASSWORD : si l'état est hébergé par GitLab, attendez-vous à un 401 (en CI : gitlab-ci-token / \$CI_JOB_TOKEN)"
    fi
  fi

  [[ -d "$envs_dir" ]] \
    || die "Répertoire des environnements introuvable : '$envs_dir' (option -d ou \$TERRAFORM_ENVS_DIR)"

  # Les environnements sont DÉCOUVERTS, jamais listés en dur : une liste figée
  # ferait ignorer un troisième environnement en silence, et un job vert qui
  # n'a rien contrôlé est pire qu'un job absent.
  local -a envs=()
  local chemin
  for chemin in "$envs_dir"/*/; do
    [[ -d "$chemin" ]] || continue
    envs+=("${chemin%/}")
  done
  ((${#envs[@]} > 0)) \
    || die "Aucun environnement dans '$envs_dir' : il faut un sous-répertoire par environnement (ex. staging/, production/)"

  # Le filtre s'applique APRÈS la découverte, pour qu'un `-e` mal orthographié
  # échoue en nommant ce qui existe, plutôt que de traiter zéro environnement
  # et de sortir en 0 — un contrôle qui n'a rien contrôlé doit être un échec.
  if [[ -n "$env_unique" ]]; then
    local -a filtre=()
    for chemin in "${envs[@]}"; do
      [[ "$(basename "$chemin")" == "$env_unique" ]] && filtre+=("$chemin")
    done
    ((${#filtre[@]} > 0)) \
      || die "Environnement '$env_unique' introuvable dans '$envs_dir'. Disponibles : $(for c in "${envs[@]}"; do basename "$c"; done | tr '\n' ' ')"
    envs=("${filtre[@]}")
  fi

  local echecs=0
  local env nom

  if [[ "$mode" == 'validate' ]]; then
    # `fmt` porte sur le parent du répertoire des environnements, pas sur les
    # environnements eux-mêmes : les modules sont leurs FRÈRES (terraform/modules),
    # pas leurs descendants, et un module mal formaté doit être signalé ici
    # plutôt qu'à la revue.
    local racine_tf
    racine_tf="$(dirname "$envs_dir")"

    lance "Format de l'arbre Terraform '$racine_tf'" \
      terraform fmt -check -recursive "$racine_tf" \
      || { echecs=$((echecs + 1)); log_warn "Correction : terraform fmt -recursive $racine_tf"; }
  else
    # Averti à l'exécution, et pas seulement dans l'en-tête : la sortie d'un job
    # se lit sans le script sous les yeux, et « Plan: 6 to add » est exactement
    # le genre de ligne qu'on prend pour une preuve.
    log_info "Mode --$mode : état PARTAGÉ et verrouillé sous ${TF_STATE_BASE_URL%/}/<env> (TERRAFORM.md §4)."
    log_warn "Ce mode exige un cluster JOIGNABLE : dès que l'état contient des ressources, Terraform les relit une par une et échoue si l'API ne répond pas."
    log_warn "Et un plan ne dit toujours pas si l'apply passera — un Deployment ne consomme aucun quota, seuls ses pods en consomment (TERRAFORM.md §9.4)."
  fi

  for env in "${envs[@]}"; do
    nom="$(basename "$env")"

    # L'adresse de l'état dépend de l'environnement traité : elle est donc
    # recomposée à CHAQUE tour, avant le moindre appel à terraform. Voir le
    # commentaire de configure_etat_distant : un export fait une seule fois
    # ferait écrire les trois environnements dans le même état.
    [[ "$mode" == 'validate' ]] || configure_etat_distant "$nom"

    if [[ "$mode" == 'validate' ]]; then
      # `-backend=false` fait toute la différence entre les deux modes : sans
      # lui, `init` résout le backend, donc toucherait l'état (et exigerait des
      # identifiants le jour où le backend `http` du §4 sera en place). Ce qui
      # reste contacté, c'est le registre des providers — le mode est hors ligne
      # vis-à-vis du CLUSTER, pas du réseau.
      if ! lance "[$nom] Initialisation sans backend" \
        terraform -chdir="$env" init -backend=false -input=false -no-color; then
        # Sans init, `validate` échouerait de toute façon en réclamant les
        # providers : l'enchaîner ajouterait une erreur qui masque la vraie.
        echecs=$((echecs + 1))
        log_warn "[$nom] Validation non jouée : l'initialisation a échoué"
        continue
      fi

      lance "[$nom] Validation de la configuration" \
        terraform -chdir="$env" validate -no-color \
        || echecs=$((echecs + 1))
    elif [[ "$mode" == 'apply' ]]; then
      if ! lance "[$nom] Initialisation" \
        terraform -chdir="$env" init -input=false -no-color; then
        echecs=$((echecs + 1))
        log_warn "[$nom] Apply non joué : l'initialisation a échoué"
        log_warn "[$nom] Si le message parle de « Backend configuration changed », c'est la bascule vers l'état partagé : jouer UNE fois \`terraform -chdir=$env init -migrate-state\` (TERRAFORM.md §4.4)"
        continue
      fi

      # ⚠️ Sur un environnement dont le namespace préexiste, cet apply échoue sur
      # « already exists » tant que l'objet n'a pas été importé (TERRAFORM.md
      # §10.1). L'échec est le bon comportement : importer automatiquement
      # reviendrait à adopter sans le dire des ressources créées par quelqu'un
      # d'autre.
      if [[ -f "$env/$FICHIER_PLAN" ]]; then
        # LE chemin de la CI. `apply <plan>` n'a pas besoin de
        # `-auto-approve` — un plan enregistré ne demande aucune confirmation,
        # il a déjà été décidé. Et il ne PEUT pas dériver : Terraform refuse le
        # fichier si l'état a bougé depuis (« Saved plan is stale »).
        log_info "[$nom] Plan enregistré présent : c'est CE plan qui est appliqué, aucun nouveau n'est calculé"
        lance "[$nom] Application du plan enregistré" \
          terraform -chdir="$env" apply -input=false -no-color "$FICHIER_PLAN" \
          || echecs=$((echecs + 1))
      elif ((exige_plan)); then
        # Compté comme un échec, et rien n'est appliqué. C'est le cas d'un
        # artefact expiré ou d'un job relancé seul : replanifier ici
        # appliquerait quelque chose que personne n'a relu, sans que la sortie
        # du job ne le distingue d'un apply normal.
        log_error "[$nom] Aucun plan enregistré ($env/$FICHIER_PLAN) alors que --require-plan est demandé : RIEN n'a été appliqué"
        log_warn "[$nom] Rejouer le job terraform-plan du même pipeline, puis relancer celui-ci"
        echecs=$((echecs + 1))
      else
        # Le mode d'un poste : personne n'a relu de plan en merge request, donc
        # il n'y a rien à trahir. `-auto-approve` est inévitable dans un job de
        # CI, qui n'a personne pour répondre ; c'est précisément pour cela que
        # `-e` est obligatoire en amont.
        log_warn "[$nom] Aucun plan enregistré : Terraform REPLANIFIE puis applique. Ce qui sera appliqué n'a donc été relu par personne."
        lance "[$nom] Application" \
          terraform -chdir="$env" apply -auto-approve -input=false -no-color \
          || echecs=$((echecs + 1))
      fi
    else
      if ! lance "[$nom] Initialisation" \
        terraform -chdir="$env" init -input=false -no-color; then
        echecs=$((echecs + 1))
        log_warn "[$nom] Plan non joué : l'initialisation a échoué"
        log_warn "[$nom] Si le message parle de « Backend configuration changed », c'est la bascule vers l'état partagé : jouer UNE fois \`terraform -chdir=$env init -migrate-state\` (TERRAFORM.md §4.4)"
        continue
      fi

      # FAIT MESURÉ, à ne pas redécouvrir : avec un `config_path` qui n'existe
      # pas, `plan` ÉCHOUE ('config_path' refers to an invalid path: stat …: no
      # such file or directory), et c'est exactement ce qui arrivait en CI tant
      # que les jobs laissaient le défaut `~/.kube/config` — l'image tourne en
      # root, `~` s'y résout en `/root`, et il n'y a pas de kubeconfig à cet
      # endroit. Les jobs exportent donc `TF_VAR_kubeconfig_path` (celui de
      # l'agent GitLab) et `TF_VAR_kube_context`.
      #
      # Second fait mesuré : avec un kubeconfig valide mais un cluster ÉTEINT et
      # un état VIDE, `plan` sortait en 0 en annonçant « 6 to add » — il n'y
      # avait rien à rafraîchir. Ce n'est plus le cas dès que l'état partagé
      # contient des ressources : Terraform les relit une par une et l'échec
      # devient visible. C'est la bascule de §4 qui a rendu ce mode utile.
      #
      # `-input=false` n'est pas décoratif : sans lui, une variable sans défaut
      # ferait attendre une saisie et le job resterait bloqué jusqu'au timeout.
      #
      # `-lock=false` sur un PLAN, et JAMAIS sur un apply : un plan ne persiste
      # aucun état, il n'a donc rien à protéger. Prendre le verrou ici ferait
      # échouer — ou attendre — tout pipeline de MR lancé pendant qu'un autre
      # plan tourne, alors que les plans concurrents sont précisément ce qu'une
      # équipe produit en permanence. Le verrou est l'affaire de l'apply.
      # `-out` est ce qui rend l'apply honnête : le plan relu en merge request
      # est publié en artefact, et c'est lui que `--apply --require-plan`
      # applique, au lieu d'en recalculer un autre.
      if lance "[$nom] Plan" \
        terraform -chdir="$env" plan -input=false -lock=false -no-color -out="$FICHIER_PLAN"; then
        resume_plan "$env" "$nom"
      else
        echecs=$((echecs + 1))
        # Un plan à moitié écrit appliquerait n'importe quoi. Mieux vaut aucun
        # artefact qu'un artefact douteux : --require-plan fera alors échouer
        # l'apply, ce qui est exactement ce qu'on veut après un plan rouge.
        rm -f "$env/$FICHIER_PLAN" "$env/$FICHIER_RESUME"
      fi
    fi
  done

  if ((echecs > 0)); then
    log_error "Bilan : $echecs contrôle(s) en échec sur ${#envs[@]} environnement(s) (mode $mode)"
    exit 1
  fi

  log_info "Bilan : tout est passé sur ${#envs[@]} environnement(s) (mode $mode)"
  exit 0
}

main "$@"
