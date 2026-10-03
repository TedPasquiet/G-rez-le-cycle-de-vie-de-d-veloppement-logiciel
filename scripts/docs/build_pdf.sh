#!/usr/bin/env bash
#
# build_pdf.sh
#
# Produit les livrables PDF à partir de leur source Markdown, en passant par un
# HTML accessible. Jusqu'ici cette chaîne se jouait à la main (`npx marked` puis
# Chrome en mode headless) : rien ne garantissait que deux PDF sortent avec la
# même mise en page, ni qu'ils soient lisibles par un lecteur d'écran.
#
# Pourquoi un PDF « balisé ». Un PDF ordinaire est une suite de glyphes posés
# sur une page : un lecteur d'écran y lit du texte sans savoir ce qui est un
# titre, un tableau ou une image. Un PDF balisé (tagged PDF) embarque l'arbre
# de structure du document — titres, paragraphes, tableaux avec leurs
# en-têtes, images avec leur texte alternatif — et sa langue. Chrome le
# produit à partir de la structure du HTML : c'est donc le HTML qu'il faut
# soigner, et c'est ce que fait ce script.
#
# En gros, pour chaque document :
#   1. il remplace chaque bloc Mermaid par une image, avec un texte alternatif
#      (`accTitle` / `accDescr` du schéma s'ils existent, sinon le titre de la
#      section qui le contient) ;
#   2. il rend ces schémas en SVG (ou en PNG) avec mermaid-cli ;
#   3. il convertit le Markdown en HTML avec `marked`, et l'enveloppe dans une
#      page qui déclare sa langue (`<html lang="fr">`), son titre (`<title>`)
#      et une feuille de style d'impression ;
#   4. il imprime cette page en PDF avec Chrome headless, signets compris ;
#   5. il VÉRIFIE le fichier produit : arbre de structure, marquage, langue,
#      signets. Un PDF non balisé fait échouer le script — un contrôle qu'on
#      se contente d'annoncer ne vaut rien.
#
# Les options :
#   -o, --output-dir <rép>   Où écrire les PDF. Par défaut : à côté de chaque
#                            source (donc docs/ pour les livrables).
#   -w, --work-dir <rép>     Où garder les fichiers intermédiaires (HTML,
#                            schémas rendus). Par défaut : un répertoire
#                            temporaire, supprimé à la fin.
#       --format <svg|png>   Format des schémas Mermaid. Par défaut : svg
#                            (vectoriel, net à l'impression). `png` pour un
#                            lecteur PDF qui afficherait mal le SVG.
#       --html-only          S'arrête après le HTML (il faut alors -w).
#   -h, --help               Affiche l'aide.
#
# Sans argument, le script traite les cinq livrables :
#   docs/documentation-ci-cd-complete.md   docs/rapport-performance.md
#   docs/documentation-infrastructure.md   docs/plan-optimisation-release.md
#   docs/schema-architecture.md
#
# Les variables d'environnement :
#   CHROME_BIN            Le binaire Chrome ou Chromium. Par défaut : cherché
#                         aux emplacements habituels de macOS et de Linux.
#   MARKED_VERSION        Version de `marked` (défaut : 16.4.2).
#   MERMAID_CLI_VERSION   Version de `@mermaid-js/mermaid-cli` (défaut : 11.17.0).
#   Les deux sont figées, pour la même raison que les images du pipeline : un
#   rendu qui change tout seul d'un jour à l'autre ne se relit pas.
#
# Ce que renvoie le script :
#   0 = ok · 1 = problème de config ou d'exécution · 4 = un PDF produit n'est
#   pas balisé (structure, marquage ou langue absents)
#
# Exemples :
#   scripts/docs/build_pdf.sh                          # les cinq livrables
#   scripts/docs/build_pdf.sh -o /tmp/pdf docs/plan-optimisation-release.md
#   scripts/docs/build_pdf.sh -w /tmp/travail --html-only RELEASE.md

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

usage() { sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

readonly MARKED_VERSION="${MARKED_VERSION:-16.4.2}"
readonly MERMAID_CLI_VERSION="${MERMAID_CLI_VERSION:-11.17.0}"

readonly -a LIVRABLES=(
  docs/documentation-ci-cd-complete.md
  docs/rapport-performance.md
  docs/documentation-infrastructure.md
  docs/plan-optimisation-release.md
  docs/schema-architecture.md
)

# Cherche Chrome là où il s'installe d'ordinaire. $CHROME_BIN l'emporte : c'est
# déjà le nom que `npm test` du front attend (README.md), autant ne pas en
# inventer un second.
trouve_chrome() {
  local candidat
  if [[ -n "${CHROME_BIN:-}" ]]; then
    [[ -x "$CHROME_BIN" ]] || die "CHROME_BIN ne désigne pas un exécutable : '$CHROME_BIN'"
    printf '%s\n' "$CHROME_BIN"
    return
  fi
  for candidat in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    google-chrome google-chrome-stable chromium chromium-browser; do
    if [[ -x "$candidat" ]]; then
      printf '%s\n' "$candidat"
      return
    fi
    if command -v "$candidat" >/dev/null 2>&1; then
      command -v "$candidat"
      return
    fi
  done
  die "Chrome ou Chromium introuvable : renseigner CHROME_BIN"
}

# Feuille de style d'impression. Chaque règle répond à un défaut d'accessibilité
# ou de lisibilité précis ; rien n'y est décoratif.
ecrit_css() {
  cat <<'CSS'
/* A4, marges qui laissent la place d'une reliure et d'annotations. */
@page { size: A4; margin: 18mm 15mm 18mm 15mm; }

/* Corps en 11 pt : c'est le plancher retenu pour TOUT le document, tableaux
   et code compris. Une police plus petite dans les tableaux est exactement ce
   qui les rend illisibles à l'impression et à la loupe d'écran. */
html { font-size: 11pt; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue",
    Helvetica, Arial, "Noto Sans", "Liberation Sans", sans-serif;
  /* #1f2933 sur blanc : rapport de contraste 14,8:1 (le niveau AA demande 4,5). */
  color: #1f2933;
  background: #ffffff;
  line-height: 1.5;
  margin: 0;
  /* Aligné à gauche, jamais justifié : la justification crée des « rivières »
     de blancs qui gênent la lecture, en particulier en cas de dyslexie. */
  text-align: left;
  overflow-wrap: break-word;
}

h1, h2, h3, h4, h5, h6 {
  color: #111827;
  line-height: 1.25;
  /* Un titre ne reste jamais seul en bas de page, séparé de son texte. */
  break-after: avoid;
  page-break-after: avoid;
}
h1 { font-size: 22pt; border-bottom: 2px solid #1f2933; padding-bottom: 6pt; margin: 0 0 14pt; }
h2 { font-size: 16pt; border-bottom: 1px solid #9aa5b1; padding-bottom: 4pt; margin: 22pt 0 10pt; }
h3 { font-size: 13pt; margin: 18pt 0 8pt; }
h4, h5, h6 { font-size: 11.5pt; margin: 14pt 0 6pt; }

p, ul, ol, blockquote, table, pre, figure { margin: 0 0 10pt; }
li { margin-bottom: 3pt; }
p, li { orphans: 3; widows: 3; }

/* Les liens sont soulignés ET colorés : la couleur seule ne les signalerait
   pas à un lecteur daltonien, ni sur une impression en noir et blanc.
   #1d4ed8 sur blanc : 6,7:1. */
a { color: #1d4ed8; text-decoration: underline; }

/* Tableaux : jamais plus larges que la page. `table-layout: auto` laisse les
   colonnes se répartir selon leur contenu. Un mot ordinaire n'est jamais
   coupé (`break-word` ne coupe qu'en dernier recours). Ce sont les longs
   jetons de code — nom de fichier, variable, URL — qui poussent un tableau
   hors de la marge, où le texte serait simplement perdu : ils reçoivent des
   points de césure à leurs séparateurs (voir ajoute_cesures). `anywhere`,
   essayé d'abord, coupait « I1 », « front » et « 8080 » en deux lignes. */
table {
  border-collapse: collapse;
  width: 100%;
  max-width: 100%;
  table-layout: auto;
}
th, td {
  border: 1px solid #7b8794;
  padding: 4pt 6pt;
  vertical-align: top;
  text-align: left;
  overflow-wrap: break-word;
  word-break: normal;
}
th { background: #e4e7eb; color: #111827; font-weight: 700; }
/* La ligne d'en-tête est répétée en haut de chaque page que le tableau
   traverse : sans elle, la suite d'un long tableau n'a plus de colonnes
   nommées. */
thead { display: table-header-group; }
tr { break-inside: avoid; page-break-inside: avoid; }

/* Code : à la ligne plutôt qu'en défilement horizontal, qui n'existe pas sur
   du papier. #1f2933 sur #f1f3f5 : 13,3:1. */
code, pre {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  font-size: 11pt;
}
code { background: #f1f3f5; padding: 0 2pt; border-radius: 2pt; overflow-wrap: break-word; }
pre {
  background: #f1f3f5;
  border: 1px solid #cbd2d9;
  padding: 8pt;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  line-height: 1.35;
}
pre code { background: none; padding: 0; }

/* Citations (les encadrés « ⚠️ » du dépôt). #3d4852 sur #f6f8fa : 8,8:1. */
blockquote {
  border-left: 4px solid #52606d;
  background: #f6f8fa;
  color: #3d4852;
  padding: 8pt 12pt;
}
blockquote > :last-child { margin-bottom: 0; }

/* Images, captures et schémas : jamais plus larges que la page, jamais
   coupés entre deux pages, jamais plus hauts qu'une page. */
img { max-width: 100%; height: auto; }
figure.schema, p > img {
  break-inside: avoid;
  page-break-inside: avoid;
}
figure.schema { text-align: center; }
figure.schema img { max-height: 235mm; }

hr { border: 0; border-top: 1px solid #9aa5b1; margin: 16pt 0; }
CSS
}

# Échappe un texte pour un attribut HTML ou un contenu de balise.
echappe_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Pose un point de césure facultatif (<wbr>) après chaque séparateur des longs
# jetons de code en ligne : `MICROCRM_CORS_ALLOWED_ORIGINS` peut alors passer à
# la ligne après un `_` au lieu d'élargir sa colonne au-delà de la page. Les
# jetons courts sont laissés entiers. <wbr> n'a aucun effet sur le texte lu
# par une synthèse vocale ni sur un copier-coller.
ajoute_cesures() {
  awk '
    {
      reste = $0; sortie = ""
      while (match(reste, /<code>[^<]*<\/code>/)) {
        contenu = substr(reste, RSTART + 6, RLENGTH - 13)
        if (length(contenu) > 12) gsub(/[_\/.:=,-]/, "&<wbr>", contenu)
        sortie = sortie substr(reste, 1, RSTART - 1) "<code>" contenu "</code>"
        reste = substr(reste, RSTART + RLENGTH)
      }
      print sortie reste
    }
  '
}

# Remplace chaque bloc ```mermaid par une image, et écrit sa source à part.
#
# Le texte alternatif vient, dans l'ordre : de `accDescr` et `accTitle` (les
# deux directives d'accessibilité que Mermaid sait lire dans un schéma), sinon
# du titre de la section qui contient le schéma. Ce repli ne décrit pas le
# schéma — il dit de quoi il parle et renvoie au texte qui l'entoure. C'est
# honnête, pas suffisant : un schéma sans `accDescr` est signalé sur stderr.
#
# Arguments : <source.md> <répertoire de travail> <préfixe> <extension>
extrait_schemas() {
  local source="$1" travail="$2" prefixe="$3" extension="$4"
  awk -v travail="$travail" -v prefixe="$prefixe" -v extension="$extension" '
    function echappe(texte) {
      gsub(/&/, "\\&amp;", texte)
      gsub(/</, "\\&lt;", texte)
      gsub(/>/, "\\&gt;", texte)
      gsub(/"/, "\\&quot;", texte)
      return texte
    }
    function nettoie(texte) {
      gsub(/[*_`]/, "", texte)
      sub(/^[ \t]+/, "", texte)
      sub(/[ \t]+$/, "", texte)
      return texte
    }
    BEGIN { dans_bloc = 0; dans_schema = 0; numero = 0; section = "" }
    /^[ \t]*```/ {
      if (!dans_bloc && $0 ~ /^[ \t]*```mermaid[ \t]*$/) {
        dans_bloc = 1; dans_schema = 1; numero++
        fichier = sprintf("%s/%s-schema-%02d.mmd", travail, prefixe, numero)
        printf "" > fichier
        titre_acc = ""; descr_acc = ""
        next
      }
      if (dans_schema) {
        close(fichier)
        dans_bloc = 0; dans_schema = 0
        if (descr_acc != "") {
          alt = (titre_acc != "" ? titre_acc " — " : "") descr_acc
        } else {
          printf "%s-schema-%02d : pas de accDescr, texte alternatif de repli\n", prefixe, numero > "/dev/stderr"
          alt = "Schéma" (titre_acc != "" ? " : " titre_acc : (section != "" ? " de la section « " section " »" : ""))
          alt = alt ". Son contenu est commenté dans le texte voisin."
        }
        printf "\n<figure class=\"schema\"><img src=\"file://%s/%s-schema-%02d.%s\" alt=\"%s\"></figure>\n\n", \
          travail, prefixe, numero, extension, echappe(alt)
        next
      }
      dans_bloc = !dans_bloc
      print
      next
    }
    dans_schema {
      print > fichier
      if ($0 ~ /^[ \t]*accTitle[ \t]*:/) { ligne = $0; sub(/^[ \t]*accTitle[ \t]*:[ \t]*/, "", ligne); titre_acc = ligne }
      if ($0 ~ /^[ \t]*accDescr[ \t]*:/) { ligne = $0; sub(/^[ \t]*accDescr[ \t]*:[ \t]*/, "", ligne); descr_acc = ligne }
      next
    }
    !dans_bloc && /^#+[ \t]/ {
      ligne = $0
      sub(/^#+[ \t]+/, "", ligne)
      section = nettoie(ligne)
    }
    { print }
  ' "$source"
}

# Le premier titre de niveau 1 du document, sans marque Markdown : c'est lui
# qui devient le <title> de la page, donc le titre affiché par le lecteur PDF
# et annoncé par le lecteur d'écran à l'ouverture.
titre_du_document() {
  awk '
    /^[ \t]*```/ { dans_bloc = !dans_bloc; next }
    !dans_bloc && /^#[ \t]/ { sub(/^#[ \t]+/, ""); gsub(/[*_`]/, ""); print; exit }
  ' "$1"
}

# Vérifie qu'un PDF est balisé. On lit le fichier lui-même : Chrome écrit le
# catalogue du PDF en clair, donc ces clés s'y cherchent sans outil dédié.
#   /StructTreeRoot  l'arbre de structure (titres, tableaux, figures)
#   /MarkInfo        le marquage « ce document est balisé »
#   /Lang            la langue, sans laquelle une synthèse vocale lit le
#                    français avec la phonétique de sa langue par défaut
#   /Outlines        les signets — utiles, mais leur absence n'invalide pas
#                    le balisage : simple avertissement
verifie_pdf() {
  local pdf="$1" cle manque=0
  for cle in /StructTreeRoot /MarkInfo /Lang; do
    if LC_ALL=C grep -a -q -- "$cle" "$pdf"; then
      log_info "  $cle présent"
    else
      log_error "  $cle ABSENT de $pdf"
      manque=1
    fi
  done
  if LC_ALL=C grep -a -q -- "/Lang (fr" "$pdf"; then
    log_info "  langue déclarée : fr"
  else
    log_error "  la langue déclarée n'est pas le français dans $pdf"
    manque=1
  fi
  if LC_ALL=C grep -a -q -- "/Outlines" "$pdf"; then
    log_info "  /Outlines présent (signets)"
  else
    log_warn "  /Outlines absent : ce Chrome ne génère pas les signets"
  fi
  return "$manque"
}

construit() {
  local source="$1" sortie="$2" travail="$3" format="$4" html_seul="$5" chrome="$6"
  local nom titre html pdf schema rendu
  nom="$(basename "$source" .md)"
  html="$travail/$nom.html"
  pdf="$sortie/$nom.pdf"

  log_info "$source"

  titre="$(titre_du_document "$source")"
  [[ -n "$titre" ]] || die "Aucun titre de niveau 1 dans $source : la page n'aurait pas de <title>"

  # 1. Les schémas sortent du Markdown.
  extrait_schemas "$source" "$travail" "$nom" "$format" >"$travail/$nom.md"

  # 2. Rendu des schémas. mermaid-cli pilote un navigateur : on lui donne le
  #    Chrome déjà installé plutôt que de le laisser en télécharger un second.
  for schema in "$travail/$nom"-schema-*.mmd; do
    [[ -e "$schema" ]] || continue
    rendu="${schema%.mmd}.$format"
    PUPPETEER_SKIP_DOWNLOAD=1 PUPPETEER_EXECUTABLE_PATH="$chrome" \
      npx -y "@mermaid-js/mermaid-cli@$MERMAID_CLI_VERSION" \
      -i "$schema" -o "$rendu" -b white -s 2 --quiet ||
      die "Rendu Mermaid en échec : $schema"
    [[ -s "$rendu" ]] || die "Rendu Mermaid vide : $rendu"
  done

  # 3. Markdown -> HTML, puis la page. `<base>` désigne le répertoire de la
  #    SOURCE : les chemins relatifs du document (captures/…) restent valides
  #    alors que le HTML est écrit ailleurs.
  npx -y "marked@$MARKED_VERSION" --gfm -i "$travail/$nom.md" -o "$travail/$nom.corps.html" ||
    die "Conversion Markdown en échec : $source"
  {
    printf '<!doctype html>\n<html lang="fr">\n<head>\n<meta charset="utf-8">\n'
    printf '<title>%s</title>\n' "$(printf '%s' "$titre" | echappe_html)"
    printf '<base href="file://%s/">\n' "$(cd "$(dirname "$source")" && pwd)"
    printf '<style>\n'
    ecrit_css
    printf '</style>\n</head>\n<body>\n<main>\n'
    # `scope="col"` : dit explicitement qu'une cellule d'en-tête nomme sa
    # colonne. marked ne le pose pas, et c'est ce qui permet à un lecteur
    # d'écran d'annoncer « colonne Variable : STAGING_NAMESPACE ».
    sed -e 's/<th>/<th scope="col">/g' -e 's/<th align=/<th scope="col" align=/g' \
      "$travail/$nom.corps.html" | ajoute_cesures
    printf '</main>\n</body>\n</html>\n'
  } >"$html"

  if LC_ALL=C grep -q '<img[^>]*alt=""' "$html" || LC_ALL=C grep '<img' "$html" | LC_ALL=C grep -q -v 'alt='; then
    die "Une image de $html n'a pas de texte alternatif (voir scripts/tests/check_accessibilite_docs.py)"
  fi
  log_info "  HTML : $html (lang=fr, titre « $titre »)"

  [[ "$html_seul" == true ]] && return 0

  # 4. HTML -> PDF. Chrome balise le PDF par défaut (l'option qui existe est
  #    celle qui le DÉSACTIVE, --disable-pdf-tagging) ; les signets, eux, se
  #    demandent. Pas d'en-tête ni de pied de page : Chrome y écrirait le
  #    chemin du fichier temporaire.
  "$chrome" --headless=new --disable-gpu --no-pdf-header-footer \
    --generate-pdf-document-outline \
    --print-to-pdf="$pdf" "file://$html" >/dev/null 2>&1 ||
    die "Chrome n'a pas produit $pdf"
  [[ -s "$pdf" ]] || die "PDF vide ou absent : $pdf"
  log_info "  PDF : $pdf ($(wc -c <"$pdf" | tr -d ' ') octets)"

  # 5. Le contrôle.
  verifie_pdf "$pdf"
}

main() {
  local sortie='' travail='' format='svg' html_seul=false garder=true
  local -a sources=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o | --output-dir) sortie="${2:?}"; shift 2 ;;
      -w | --work-dir) travail="${2:?}"; shift 2 ;;
      --format) format="${2:?}"; shift 2 ;;
      --html-only) html_seul=true; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) die "Option inconnue : '$1' (voir --help)" ;;
      *) sources+=("$1"); shift ;;
    esac
  done

  [[ "$format" == svg || "$format" == png ]] || die "Format inconnu : '$format' (svg ou png)"
  if [[ "$html_seul" == true && -z "$travail" ]]; then
    die "--html-only demande -w : sans répertoire de travail conservé, le HTML serait supprimé"
  fi

  require_cmd npx awk sed grep
  local chrome
  chrome="$(trouve_chrome)"

  if [[ ${#sources[@]} -eq 0 ]]; then
    local livrable
    for livrable in "${LIVRABLES[@]}"; do
      sources+=("$REPO_ROOT/$livrable")
    done
  fi

  if [[ -z "$travail" ]]; then
    travail="$(mktemp -d "${TMPDIR:-/tmp}/build_pdf.XXXXXX")"
    garder=false
  else
    mkdir -p "$travail"
  fi
  travail="$(cd "$travail" && pwd)"
  if [[ "$garder" == false ]]; then
    # shellcheck disable=SC2064  # le chemin doit être figé MAINTENANT
    trap "rm -rf '$travail'" EXIT
  fi

  local source destination defauts=0
  for source in "${sources[@]}"; do
    [[ -f "$source" ]] || die "Document introuvable : '$source'"
    source="$(cd "$(dirname "$source")" && pwd)/$(basename "$source")"
    if [[ -n "$sortie" ]]; then
      mkdir -p "$sortie"
      destination="$(cd "$sortie" && pwd)"
    else
      destination="$(dirname "$source")"
    fi
    construit "$source" "$destination" "$travail" "$format" "$html_seul" "$chrome" || defauts=1
  done

  if [[ "$defauts" -ne 0 ]]; then
    log_error "Au moins un PDF n'est pas balisé."
    exit 4
  fi
  log_info "Terminé : ${#sources[@]} document(s)."
}

main "$@"
