#!/usr/bin/env python3
"""check_accessibilite_docs.py

Contrôle mécanique de l'accessibilité des documents livrables en Markdown.

Pourquoi ce script existe. Le plan de mise à jour, de sauvegarde et de retour
arrière doit rester lisible par tous ceux qui s'en servent, y compris avec un
lecteur d'écran, une loupe d'écran ou une synthèse vocale. Une partie de ce que
le RGAA 4.1 et les WCAG 2.1 demandent à un document se vérifie à la machine ;
c'est cette partie, et elle seule, que ce script contrôle. Le reste (justesse
d'un texte alternatif, clarté d'une phrase) demande une relecture humaine, et
aucun code de sortie ne la remplace.

Ce qui est contrôlé, et le critère auquel ça se rattache :

  TITRE     un seul titre de niveau 1, et aucun saut de niveau en descendant
            (un `###` directement sous un `#`). Les lecteurs d'écran naviguent
            de titre en titre : un niveau sauté fait croire à une section
            manquante.                              RGAA 9.1 / WCAG 1.3.1, 2.4.6
  IMAGE     chaque image porte un texte alternatif non vide, et ce texte n'est
            pas un nom de fichier.                  RGAA 1.1, 1.2 / WCAG 1.1.1
  TABLEAU   chaque tableau a une ligne d'en-tête dont aucune cellule n'est
            vide : sans elle, une cellule lue isolément n'a pas de sens.
                                                    RGAA 5.6, 5.7 / WCAG 1.3.1
  LIEN      aucun lien dont le libellé est « ici », « cliquez ici », « lien »,
            « lire la suite »... ni vide. Un lecteur d'écran liste les liens
            hors de leur phrase.                    RGAA 6.1, 6.2 / WCAG 2.4.4
  SCHEMA    chaque bloc Mermaid est accompagné d'un texte à proximité : un
            paragraphe de prose, une liste ou un tableau, dans les blocs qui
            l'entourent. Un schéma est une image : sans équivalent textuel,
            son contenu n'existe pas pour qui ne le voit pas.
                                                    RGAA 1.6 / WCAG 1.1.1
  SYMBOLE   aucun pictogramme (⚠️ ✅ ❌ 🟢 🔴 ✋ ✗ ✓...) ne porte seul une
            information : ni seul dans une cellule de tableau, ni seul sur
            une ligne, ni seul dans un libellé de schéma.
                                                    RGAA 3.1 / WCAG 1.4.1

Ce qui est seulement SIGNALÉ, sans peser sur le code de sortie (`--strict`
pour en faire des défauts) :

  PHRASE    les phrases de plus de 60 mots (seuil réglable par
            `--max-mots`). Une phrase longue n'est pas une faute ; c'est un
            endroit à relire.                       WCAG 3.1.5 (niveau AAA)

Ce que ce script ne sait PAS vérifier, et qu'il ne prétend pas couvrir : la
pertinence d'un texte alternatif, la fidélité de la description d'un schéma,
le développement des sigles, le contraste des couleurs d'un schéma rendu, la
langue déclarée (elle se déclare dans le HTML et le PDF, pas en Markdown :
voir scripts/docs/build_pdf.sh, qui la pose et la contrôle).

Usage :
  scripts/tests/check_accessibilite_docs.py [options] [fichier.md ...]

Sans fichier, le script contrôle les livrables : les cinq documents de docs/
qui partent en PDF, et RELEASE.md (le plan de mise à jour, de sauvegarde et
de retour arrière).

Options :
  --strict        les signalements (PHRASE) deviennent des défauts.
  --max-mots N    longueur de phrase à partir de laquelle on signale (60).
  --quiet         n'affiche que les défauts et le total.
  -h, --help      affiche cette aide.

Codes de sortie :
  0 = aucun défaut · 1 = au moins un défaut · 2 = erreur d'usage ou fichier
  introuvable

Python standard uniquement, comme tout scripts/ci/ : aucune dépendance à
installer, donc le contrôle se joue sur un poste nu comme dans une image de CI.
"""

import os
import re
import sys

RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Les livrables : ce qui est remis au jury en PDF, plus le plan de release.
LIVRABLES = [
    "docs/documentation-ci-cd-complete.md",
    "docs/rapport-performance.md",
    "docs/documentation-infrastructure.md",
    "docs/plan-optimisation-release.md",
    "docs/schema-architecture.md",
    "RELEASE.md",
]

# Libellés de lien qui ne disent rien hors de leur phrase. Comparés après
# passage en minuscules et retrait de la ponctuation de bord.
LIBELLES_CREUX = {
    "ici",
    "cliquez ici",
    "cliquer ici",
    "clique ici",
    "ce lien",
    "lien",
    "le lien",
    "là",
    "lire la suite",
    "en savoir plus",
    "voir",
    "voir ici",
    "plus",
    "suite",
    "here",
    "click here",
    "link",
    "this link",
    "more",
    "read more",
}

# Pictogrammes porteurs de sens dans ce dépôt. Les flèches typographiques
# (→, ↔) n'y figurent pas : elles sont lues par les synthèses vocales et
# tiennent lieu de ponctuation, pas de verdict.
SYMBOLES = "⚠✅❌🟢🔴🟡🟠✋✗✓✔✘⛔🚫❗❓⭐🔒🔓👉👍👎"
RE_SYMBOLE = re.compile("[" + SYMBOLES + "]")
# Sélecteur de variante emoji et jointure : à ignorer pour savoir ce qui reste.
RE_INVISIBLE = re.compile("[️‍]")

RE_TITRE = re.compile(r"^(#{1,6})\s+(.*\S)\s*$")
RE_BARRIERE = re.compile(r"^\s*(```+|~~~+)\s*([A-Za-z0-9_+-]*)")
RE_IMAGE_MD = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)")
RE_IMAGE_HTML = re.compile(r"<img\b[^>]*>", re.IGNORECASE)
RE_ALT_HTML = re.compile(r"""\balt\s*=\s*("([^"]*)"|'([^']*)')""", re.IGNORECASE)
RE_LIEN_MD = re.compile(r"(?<!!)\[([^\]]*)\]\(([^)]+)\)")
RE_LIEN_HTML = re.compile(r"<a\b[^>]*>(.*?)</a>", re.IGNORECASE | re.DOTALL)
RE_SEPARATEUR_TABLEAU = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
RE_EXTENSION_IMAGE = re.compile(r"\.(png|jpe?g|gif|svg|webp)$", re.IGNORECASE)
RE_LIBELLE_MERMAID = re.compile(r'"([^"]*)"|\|([^|]*)\|')


class Defaut:
    """Un constat : où, de quelle famille, et ce qu'il faut corriger."""

    def __init__(self, fichier, ligne, famille, message, bloquant=True):
        self.fichier = fichier
        self.ligne = ligne
        self.famille = famille
        self.message = message
        self.bloquant = bloquant

    def __str__(self):
        marque = "DÉFAUT" if self.bloquant else "à relire"
        return f"{self.fichier}:{self.ligne}: [{self.famille}] {marque} : {self.message}"


def cellules(ligne):
    """Découpe une ligne de tableau GFM en cellules, sans les barres de bord."""
    texte = ligne.strip()
    if texte.startswith("|"):
        texte = texte[1:]
    if texte.endswith("|") and not texte.endswith("\\|"):
        texte = texte[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", texte)]


def sans_code(texte):
    """Retire le code en ligne : un `⚠` cité comme code n'est pas un verdict."""
    return re.sub(r"`[^`]*`", "", texte)


def reste_apres_symboles(texte):
    """Ce qui reste d'un texte une fois les pictogrammes retirés."""
    texte = RE_SYMBOLE.sub("", RE_INVISIBLE.sub("", texte))
    return re.sub(r"[\s*_~>|:.,;!?()\[\]«»\"'-]+", "", texte)


def symbole_seul(texte):
    """Vrai si le texte contient un pictogramme et rien d'autre de lisible."""
    texte = sans_code(texte)
    return bool(RE_SYMBOLE.search(texte)) and reste_apres_symboles(texte) == ""


def decouper(lignes):
    """Classe chaque ligne : hors bloc de code, dans un bloc, et de quel langage.

    Rend une liste de tuples (numéro, texte, etat) où etat vaut `texte`,
    `barriere` ou le langage du bloc (`mermaid`, `shell`, `code`...). Tout le
    reste du script s'appuie dessus : un `#` dans un bloc shell est un
    commentaire, pas un titre.
    """
    resultat = []
    dans_bloc = None
    marque = None
    for numero, ligne in enumerate(lignes, start=1):
        m = RE_BARRIERE.match(ligne)
        if dans_bloc is None:
            if m:
                marque = m.group(1)[0] * 3
                dans_bloc = (m.group(2) or "code").lower()
                resultat.append((numero, ligne, "barriere"))
            else:
                resultat.append((numero, ligne, "texte"))
        else:
            if m and m.group(1).startswith(marque) and not m.group(2):
                resultat.append((numero, ligne, "barriere"))
                dans_bloc = None
            else:
                resultat.append((numero, ligne, dans_bloc))
    return resultat


def controle_titres(fichier, decoupe):
    defauts = []
    precedent = 0
    nombre_h1 = 0
    for numero, ligne, etat in decoupe:
        if etat != "texte":
            continue
        m = RE_TITRE.match(ligne)
        if not m:
            continue
        niveau = len(m.group(1))
        titre = m.group(2)
        if niveau == 1:
            nombre_h1 += 1
            if nombre_h1 > 1:
                defauts.append(
                    Defaut(fichier, numero, "TITRE", f"second titre de niveau 1 : « {titre} »")
                )
        if precedent and niveau > precedent + 1:
            defauts.append(
                Defaut(
                    fichier,
                    numero,
                    "TITRE",
                    f"saut du niveau {precedent} au niveau {niveau} : « {titre} »",
                )
            )
        if precedent == 0 and niveau != 1:
            defauts.append(
                Defaut(
                    fichier,
                    numero,
                    "TITRE",
                    f"le premier titre est de niveau {niveau}, pas de niveau 1 : « {titre} »",
                )
            )
        if symbole_seul(titre):
            defauts.append(Defaut(fichier, numero, "SYMBOLE", "titre réduit à un pictogramme"))
        precedent = niveau
    if nombre_h1 == 0:
        defauts.append(Defaut(fichier, 1, "TITRE", "aucun titre de niveau 1"))
    return defauts


def controle_images(fichier, decoupe):
    defauts = []
    for numero, ligne, etat in decoupe:
        if etat != "texte":
            continue
        for m in RE_IMAGE_MD.finditer(ligne):
            alt, cible = m.group(1).strip(), m.group(2)
            if not alt:
                defauts.append(
                    Defaut(fichier, numero, "IMAGE", f"image sans texte alternatif : {cible}")
                )
            elif RE_EXTENSION_IMAGE.search(alt) or alt == os.path.basename(cible):
                defauts.append(
                    Defaut(
                        fichier,
                        numero,
                        "IMAGE",
                        f"le texte alternatif est un nom de fichier : « {alt} »",
                    )
                )
        for m in RE_IMAGE_HTML.finditer(ligne):
            alt = RE_ALT_HTML.search(m.group(0))
            valeur = (alt.group(2) or alt.group(3) or "").strip() if alt else ""
            if not valeur:
                defauts.append(
                    Defaut(
                        fichier,
                        numero,
                        "IMAGE",
                        f"balise <img> sans attribut alt renseigné : {m.group(0)[:70]}",
                    )
                )
    return defauts


def controle_liens(fichier, decoupe):
    defauts = []
    for numero, ligne, etat in decoupe:
        if etat != "texte":
            continue
        texte = sans_code_preserve_liens(ligne)
        libelles = [m.group(1) for m in RE_LIEN_MD.finditer(texte)]
        libelles += [re.sub(r"<[^>]+>", "", m.group(1)) for m in RE_LIEN_HTML.finditer(texte)]
        for libelle in libelles:
            # Un lien dont le libellé est du code (`fichier.md`) garde ce code
            # comme libellé : on ne retire que les marques d'emphase.
            nu = re.sub(r"[*_`]", "", libelle).strip().strip(".:;,!?»«\"' ").lower()
            if nu == "":
                defauts.append(Defaut(fichier, numero, "LIEN", "lien au libellé vide"))
            elif nu in LIBELLES_CREUX:
                defauts.append(
                    Defaut(
                        fichier,
                        numero,
                        "LIEN",
                        f"libellé de lien non explicite hors contexte : « {libelle.strip()} »",
                    )
                )
    return defauts


def sans_code_preserve_liens(ligne):
    """Retire le code en ligne qui n'est PAS le libellé d'un lien.

    `[texte](cible)` écrit entre accents graves est un exemple de syntaxe, pas
    un lien ; mais [`fichier`](cible) est un vrai lien dont le libellé est du
    code. On neutralise donc seulement les segments de code qui contiennent un
    crochet ouvrant.
    """
    return re.sub(r"`[^`]*\[[^`]*`", "", ligne)


def controle_tableaux(fichier, decoupe):
    """En GFM, un tableau n'existe que par sa ligne de séparation `|---|`.

    Deux défauts possibles : une ligne d'en-tête dont une cellule est vide, et
    un pavé de lignes en `|` sans séparateur — qui n'est alors pas rendu comme
    un tableau du tout, donc lu comme une suite de barres verticales.
    """
    defauts = []
    lignes = [(n, l) for n, l, etat in decoupe if etat == "texte"]
    index = {n: l for n, l in lignes}
    numeros = [n for n, _ in lignes]
    vus = set()
    for position, numero in enumerate(numeros):
        ligne = index[numero]
        if not ligne.lstrip().startswith("|") or numero in vus:
            continue
        # Début d'un pavé de lignes consécutives commençant par `|`.
        pave = []
        curseur = position
        while curseur < len(numeros):
            n = numeros[curseur]
            if pave and n != pave[-1] + 1:
                break
            if not index[n].lstrip().startswith("|"):
                break
            pave.append(n)
            curseur += 1
        vus.update(pave)
        if len(pave) < 2 or not RE_SEPARATEUR_TABLEAU.match(index[pave[1]]):
            defauts.append(
                Defaut(
                    fichier,
                    pave[0],
                    "TABLEAU",
                    "tableau sans ligne d'en-tête suivie de son séparateur `|---|`",
                )
            )
            continue
        entetes = cellules(index[pave[0]])
        for rang, cellule in enumerate(entetes, start=1):
            if re.sub(r"[*_`\s]", "", cellule) == "":
                defauts.append(
                    Defaut(
                        fichier,
                        pave[0],
                        "TABLEAU",
                        f"cellule d'en-tête vide (colonne {rang}) : la colonne n'a pas de nom",
                    )
                )
        for n in pave[2:]:
            for rang, cellule in enumerate(cellules(index[n]), start=1):
                if symbole_seul(cellule):
                    nom = entetes[rang - 1] if rang <= len(entetes) else f"colonne {rang}"
                    defauts.append(
                        Defaut(
                            fichier,
                            n,
                            "SYMBOLE",
                            f"cellule réduite à un pictogramme (colonne « {nom} ») : "
                            "ajouter le mot qu'il remplace",
                        )
                    )
    return defauts


def blocs(decoupe):
    """Regroupe les lignes en blocs séparés par des lignes vides.

    Rend une liste de (numéro de première ligne, genre, texte). Les genres :
    `mermaid`, `code`, `titre`, `tableau`, `liste`, `citation`, `commentaire`,
    `regle`, `image` et `prose`.
    """
    resultat = []
    courant = []
    genre_bloc = None

    def vider():
        nonlocal courant
        if courant:
            resultat.append(classer(courant))
            courant = []

    for numero, ligne, etat in decoupe:
        if etat == "barriere":
            if genre_bloc is None:
                vider()
                genre_bloc = "ouvert"
                courant = [(numero, ligne, etat)]
            else:
                courant.append((numero, ligne, etat))
                resultat.append(classer(courant))
                courant = []
                genre_bloc = None
            continue
        if genre_bloc is not None:
            courant.append((numero, ligne, etat))
            continue
        if ligne.strip() == "":
            vider()
        elif RE_TITRE.match(ligne):
            vider()
            resultat.append((numero, "titre", ligne.strip()))
        else:
            courant.append((numero, ligne, etat))
    vider()
    return resultat


def classer(lignes_bloc):
    numero = lignes_bloc[0][0]
    etats = {etat for _, _, etat in lignes_bloc}
    texte = "\n".join(l for _, l, _ in lignes_bloc)
    if "barriere" in etats:
        langages = etats - {"barriere"}
        return (numero, "mermaid" if "mermaid" in langages else "code", texte)
    premiere = lignes_bloc[0][1].strip()
    if premiere.startswith("<!--") and texte.strip().endswith("-->"):
        return (numero, "commentaire", texte)
    if premiere.startswith("|"):
        return (numero, "tableau", texte)
    if re.match(r"^([-*+]|\d+\.)\s", premiere):
        return (numero, "liste", texte)
    if premiere.startswith(">"):
        return (numero, "citation", texte)
    if re.match(r"^(-{3,}|\*{3,}|_{3,})$", premiere):
        return (numero, "regle", texte)
    if RE_IMAGE_MD.fullmatch(premiere):
        return (numero, "image", texte)
    return (numero, "prose", texte)


# Genres de blocs qui peuvent porter l'équivalent textuel d'un schéma.
GENRES_DESCRIPTIFS = {"prose", "liste", "tableau", "citation"}
# Longueur minimale, en caractères utiles, pour qu'un bloc compte comme une
# description et non comme une simple légende de source (« _Source : x.mmd_ »).
LONGUEUR_DESCRIPTION = 120
# Nombre de blocs explorés de part et d'autre du schéma.
PORTEE = 3


def est_legende_de_source(texte):
    """Une ligne « Source : docs/schemas/x.mmd » ne décrit pas le schéma."""
    nu = re.sub(r"[*_`]", "", texte).strip().lower()
    return nu.startswith("source") and len(nu) < 260


def controle_schemas(fichier, decoupe):
    defauts = []
    liste = blocs(decoupe)
    for position, (numero, genre, texte) in enumerate(liste):
        if genre != "mermaid":
            continue
        voisins = []
        # Vers le haut, puis vers le bas, sans franchir un titre de même
        # section vers le haut au-delà de son introduction : un titre arrête
        # la recherche descendante (on entre dans une autre section), pas la
        # recherche montante (le paragraphe d'introduction est souvent juste
        # sous le titre du schéma).
        for pas in range(1, PORTEE + 1):
            if position - pas >= 0:
                g = liste[position - pas]
                if g[1] == "mermaid":
                    break
                voisins.append(g)
        for pas in range(1, PORTEE + 1):
            if position + pas < len(liste):
                g = liste[position + pas]
                if g[1] in ("titre", "mermaid"):
                    break
                voisins.append(g)
        decrit = any(
            g[1] in GENRES_DESCRIPTIFS
            and not est_legende_de_source(g[2])
            and len(re.sub(r"\s+", " ", g[2])) >= LONGUEUR_DESCRIPTION
            for g in voisins
        )
        if not decrit:
            defauts.append(
                Defaut(
                    fichier,
                    numero,
                    "SCHEMA",
                    "bloc Mermaid sans description textuelle à proximité "
                    f"(aucun paragraphe, liste ou tableau d'au moins {LONGUEUR_DESCRIPTION} "
                    f"caractères dans les {PORTEE} blocs qui l'entourent)",
                )
            )
        # Libellés du schéma réduits à un pictogramme.
        for decalage, ligne in enumerate(texte.split("\n")):
            for m in RE_LIBELLE_MERMAID.finditer(ligne):
                libelle = m.group(1) if m.group(1) is not None else m.group(2)
                libelle = re.sub(r"<br\s*/?>", " ", libelle)
                if symbole_seul(libelle):
                    defauts.append(
                        Defaut(
                            fichier,
                            numero + decalage,
                            "SYMBOLE",
                            "libellé de schéma réduit à un pictogramme",
                        )
                    )
    return defauts


def controle_symboles_lignes(fichier, decoupe):
    """Un paragraphe ou un item de liste qui ne contient qu'un pictogramme."""
    defauts = []
    for numero, ligne, etat in decoupe:
        if etat != "texte" or ligne.lstrip().startswith("|"):
            continue
        contenu = re.sub(r"^\s*([-*+]|\d+\.|>)\s*", "", ligne)
        if symbole_seul(contenu):
            defauts.append(
                Defaut(fichier, numero, "SYMBOLE", "ligne réduite à un pictogramme, sans mot")
            )
    return defauts


def controle_phrases(fichier, decoupe, max_mots, strict):
    """Signale les phrases longues, paragraphe par paragraphe."""
    defauts = []
    for numero, genre, texte in blocs(decoupe):
        if genre not in ("prose", "liste", "citation"):
            continue
        nu = re.sub(r"^\s*([-*+]|\d+\.|>)\s*", "", texte, flags=re.MULTILINE)
        nu = re.sub(r"`[^`]*`", "code", nu)
        nu = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", nu)
        nu = re.sub(r"\s+", " ", nu)
        # Fin de phrase : ponctuation forte suivie d'une majuscule, d'un
        # marqueur d'emphase ou de la fin du bloc. Le « : » et le « ; » ne
        # coupent pas — on mesure ce qu'une synthèse vocale lit d'un souffle.
        for phrase in re.split(r"(?<=[.!?…])\s+(?=[A-ZÀÂÉÈÊÎÔÛÇ*_«\"(])", nu):
            mots = [m for m in phrase.split(" ") if re.search(r"\w", m)]
            if len(mots) > max_mots:
                defauts.append(
                    Defaut(
                        fichier,
                        numero,
                        "PHRASE",
                        f"phrase de {len(mots)} mots : « {' '.join(mots[:9])}… »",
                        bloquant=strict,
                    )
                )
    return defauts


def controler(chemin, max_mots, strict):
    absolu = os.path.abspath(chemin)
    # Chemin relatif au dépôt quand le fichier en fait partie, tel quel sinon.
    relatif = os.path.relpath(absolu, RACINE) if absolu.startswith(RACINE + os.sep) else chemin
    with open(chemin, encoding="utf-8") as flux:
        lignes = flux.read().split("\n")
    decoupe = decouper(lignes)
    defauts = []
    defauts += controle_titres(relatif, decoupe)
    defauts += controle_images(relatif, decoupe)
    defauts += controle_tableaux(relatif, decoupe)
    defauts += controle_liens(relatif, decoupe)
    defauts += controle_schemas(relatif, decoupe)
    defauts += controle_symboles_lignes(relatif, decoupe)
    defauts += controle_phrases(relatif, decoupe, max_mots, strict)
    defauts.sort(key=lambda d: (d.ligne, d.famille))
    compte = {
        "titres": sum(1 for _, l, e in decoupe if e == "texte" and RE_TITRE.match(l)),
        "images": sum(
            len(RE_IMAGE_MD.findall(l)) + len(RE_IMAGE_HTML.findall(l))
            for _, l, e in decoupe
            if e == "texte"
        ),
        "tableaux": sum(
            1 for _, l, e in decoupe if e == "texte" and RE_SEPARATEUR_TABLEAU.match(l) and "|" in l
        ),
        "liens": sum(
            len(RE_LIEN_MD.findall(sans_code_preserve_liens(l)))
            for _, l, e in decoupe
            if e == "texte"
        ),
        "schemas": sum(1 for _, g, _ in blocs(decoupe) if g == "mermaid"),
    }
    return relatif, defauts, compte


def main(arguments):
    strict = False
    quiet = False
    max_mots = 60
    fichiers = []
    iterateur = iter(arguments)
    for argument in iterateur:
        if argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if argument == "--strict":
            strict = True
        elif argument == "--quiet":
            quiet = True
        elif argument == "--max-mots":
            try:
                max_mots = int(next(iterateur))
            except (StopIteration, ValueError):
                print("ERREUR : --max-mots attend un nombre entier.", file=sys.stderr)
                return 2
        elif argument.startswith("-"):
            print(f"ERREUR : option inconnue : {argument} (voir --help)", file=sys.stderr)
            return 2
        else:
            fichiers.append(argument)

    if not fichiers:
        fichiers = [os.path.join(RACINE, f) for f in LIVRABLES]

    for chemin in fichiers:
        if not os.path.isfile(chemin):
            print(f"ERREUR : fichier introuvable : {chemin}", file=sys.stderr)
            return 2

    total_defauts = 0
    total_signalements = 0
    for chemin in fichiers:
        relatif, constats, compte = controler(chemin, max_mots, strict)
        bloquants = [c for c in constats if c.bloquant]
        signalements = [c for c in constats if not c.bloquant]
        total_defauts += len(bloquants)
        total_signalements += len(signalements)
        etat = "ok   " if not bloquants else "ÉCHEC"
        print(
            f"{etat} {relatif} — {compte['titres']} titres, {compte['images']} images, "
            f"{compte['tableaux']} tableaux, {compte['liens']} liens, "
            f"{compte['schemas']} schémas : {len(bloquants)} défaut(s), "
            f"{len(signalements)} passage(s) à relire"
        )
        for constat in bloquants:
            print(f"   {constat}")
        if not quiet:
            for constat in signalements:
                print(f"   {constat}")

    print("---------------------------------------------")
    print(
        f"Résultat : {len(fichiers)} document(s), {total_defauts} défaut(s), "
        f"{total_signalements} passage(s) à relire"
    )
    return 1 if total_defauts else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
