#!/usr/bin/env python3
"""collect_security.py

Ce script transforme les rapports des scanners de sécurité du pipeline en
documents Elasticsearch, pour que le tableau de bord Kibana « sécurité » ait
quelque chose à afficher. Sans lui, les constats de Trivy et de Dependency-Check
vivent dans le journal d'un job : on les lit le jour où le job rougit, jamais
comme une tendance.

Ce qu'il lit :
    - un ou plusieurs rapports JSON de Trivy (`trivy fs --format json`,
      `trivy image --format json`) : vulnérabilités, misconfigurations, secrets ;
    - le rapport JSON d'OWASP Dependency-Check, s'il existe ;
    - `.trivyignore.yaml` : les exceptions assumées, avec leur chemin et leur
      échéance.

Ce qu'il produit — trois sortes de documents, distinguées par le champ `type` :
    - `constat`   : UNE vulnérabilité, misconfiguration ou fuite de secret
                    (sévérité, identifiant, paquet, version, version corrigée,
                    cible, type de scan, commit, date) ;
    - `scan`      : un résumé par rapport lu, avec le décompte par sévérité ;
    - `exception` : une entrée de `.trivyignore.yaml`, avec son échéance et le
                    nombre de jours qu'il lui reste.

La règle qui gouverne tout le script — la même que `collect_dora.py` :
    l'absence de donnée n'est pas un zéro. Un rapport lu qui ne contient aucun
    constat produit un document `scan` avec `total: 0` : c'est une MESURE, le
    scanner a tourné et n'a rien trouvé. Un rapport qui n'a pas été fourni ne
    produit RIEN : aucun document `scan`, donc aucun zéro affichable. Et un
    rapport illisible fait échouer le script (code 1) au lieu d'être compté pour
    zéro — un tableau de bord qui affiche « 0 vulnérabilité » parce que le
    fichier était tronqué serait pire que pas de tableau de bord.

    Corollaire, et il est écrit dans chaque document `scan` : le JSON de Trivy
    ne dit pas quels scanners ont tourné. Un rapport sans misconfiguration peut
    vouloir dire « aucune » ou « scanner non demandé ». Le champ
    `categories_observees` liste donc ce qui a été VU, pas ce qui a été cherché.

    Second corollaire : le collecteur ne voit que ce que le rapport contient.
    Les rapports de la CI sont filtrés (`--severity HIGH,CRITICAL`) et les
    exclusions y sont déjà appliquées : sur eux, MEDIUM et LOW valent 0 parce
    qu'ils n'ont pas été demandés, et `constats_couverts` vaut 0 parce que
    Trivy a retiré les constats exceptés avant d'écrire. Pour le tableau
    complet, il faut un rapport produit sans filtre ni `--ignorefile`.

Comment ça marche :
    Chaque rapport est réduit à une liste de constats. Le « composant » (back,
    front, depot) est déduit de la cible : le chemin du fichier pour un scan du
    système de fichiers, le nom de l'image pour un scan d'image. Un constat
    couvert par une entrée de `.trivyignore.yaml` (même identifiant ET même
    chemin) reçoit `statut: excepte` au lieu de `ouvert` — il reste visible,
    mais ne se compte pas avec les autres.

    À l'envoi, les documents `constat` et `scan` déjà présents pour la même
    source sont d'abord marqués `courant: false`, puis les nouveaux arrivent
    avec `courant: true`. C'est ce qui permet au tableau de bord d'afficher
    « les vulnérabilités ouvertes AUJOURD'HUI » (filtre `courant: true`) sans
    additionner les scans successifs, tout en gardant l'historique pour la
    courbe d'évolution. Les `_id` sont déterministes : rejouer la collecte sur
    le même commit remplace les documents au lieu de les doubler.

    Comme les autres scripts de `scripts/ci/`, celui-ci n'utilise que la
    bibliothèque standard : le job tourne dans python:3.12-slim, sans pip. C'est
    aussi pourquoi `.trivyignore.yaml` est lu par un petit analyseur maison et
    non par PyYAML — il ne comprend que la forme de ce fichier-là, et il le dit
    quand il ne comprend pas.

Les options :
    --trivy-report CHEMIN     Rapport JSON de Trivy. Répétable (un par scan).
                              La CI les publie sous `reports/trivy-fs.json`,
                              `reports/trivy-image-back.json` et
                              `reports/trivy-image-front.json`.
    --dependency-check-report CHEMIN
                              Rapport JSON de Dependency-Check. Répétable.
                              Le build l'écrit dans
                              back/build/reports/dependency-check-report.json
                              (`formats` contient 'JSON' dans back/build.gradle).
    --optional                Un rapport introuvable est signalé puis ignoré, au
                              lieu de faire échouer le script. Pour un job CI
                              dont un scan amont a pu ne pas tourner. Un rapport
                              présent mais invalide reste une erreur.
    --trivyignore CHEMIN      Fichier d'exceptions. Défaut : .trivyignore.yaml
                              s'il existe dans le répertoire courant.
    --no-trivyignore          Ne lit aucune exception.
    --commit SHA              Commit scanné. Défaut : $CI_COMMIT_SHA, sinon
                              `git rev-parse HEAD`, sinon absent.
    --ref NOM                 Branche ou tag. Défaut : $CI_COMMIT_REF_NAME.
    --date ISO8601            Horodatage des documents. Défaut : maintenant.
                              Sert à dater un scan rejoué sur un ancien commit.
    --output FICHIER          Écrit le JSON dans ce fichier au lieu de stdout.
    --elasticsearch URL       Envoie aussi les documents en `_bulk`.
    --es-index NOM            Index de destination. Défaut : microcrm-security

Ce que renvoie le script :
    0 = collecte terminée (même avec zéro constat : c'est un résultat)
    1 = erreur technique (aucune source, rapport introuvable ou invalide,
        fichier d'exceptions illisible, envoi Elasticsearch raté)

    ⚠️ Ce script ne juge pas : il ne sort JAMAIS en erreur parce qu'il y a des
    vulnérabilités. La porte bloquante reste `trivy --exit-code 1` dans le job
    `trivy-fs`. Mélanger les deux rôles ferait rougir le pipeline deux fois pour
    la même cause.

Exemples :
    scripts/ci/collect_security.py --trivy-report reports/trivy-fs.json
    scripts/ci/collect_security.py \\
        --trivy-report reports/trivy-fs.json \\
        --trivy-report reports/trivy-image-back.json \\
        --trivy-report reports/trivy-image-front.json \\
        --dependency-check-report back/build/reports/dependency-check-report.json \\
        --optional --elasticsearch http://elasticsearch:9200
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timezone

DEFAULT_ES_INDEX = "microcrm-security"
DEFAULT_TRIVYIGNORE = ".trivyignore.yaml"

# L'ordre sert au tri et au champ `severite_rang` : Kibana trie une chaîne par
# ordre alphabétique, et « CRITICAL < HIGH < LOW < MEDIUM » n'aide personne.
SEVERITES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
RANG = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1, "UNKNOWN": 0}

# Dependency-Check n'emploie pas toujours le vocabulaire de Trivy.
ALIAS_SEVERITE = {"MODERATE": "MEDIUM", "INFO": "LOW", "INFORMATIONAL": "LOW", "NONE": "UNKNOWN"}

SECTIONS_TRIVYIGNORE = {"vulnerabilities": "vulnerabilite", "misconfigurations": "misconfiguration",
                        "secrets": "secret", "licenses": "licence"}


class RapportInvalide(Exception):
    """Le fichier existe mais n'est pas le rapport attendu."""


def log(message: str) -> None:
    print(f"[collect_security] {message}", file=sys.stderr, flush=True)


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def severite(valeur) -> str:
    texte = str(valeur or "UNKNOWN").strip().upper()
    texte = ALIAS_SEVERITE.get(texte, texte)
    return texte if texte in RANG else "UNKNOWN"


def composant_de_chemin(chemin: str) -> str:
    """back / front / depot, d'après le premier répertoire du chemin."""
    propre = (chemin or "").replace("\\", "/").lstrip("./")
    if propre.startswith("back/"):
        return "back"
    if propre.startswith("front/"):
        return "front"
    # Tout le reste appartient au dépôt lui-même : manifestes Kubernetes, Helm,
    # Terraform, Ansible, CI, outillage racine.
    return "depot"


def composant_d_image(nom: str) -> str:
    # `…/back:1.2.3`, `…/front@sha256:…` : le dernier segment du chemin de
    # l'image, débarrassé de son tag ou de son empreinte.
    dernier = (nom or "").split("@")[0].rsplit("/", 1)[-1].split(":")[0].lower()
    for candidat in ("back", "front"):
        if candidat in dernier:
            return candidat
    return "image"


def lire_json(chemin: str):
    with open(chemin, encoding="utf-8") as fichier:
        try:
            return json.load(fichier)
        except json.JSONDecodeError as exc:
            raise RapportInvalide(f"{chemin} : JSON invalide ({exc.msg}, ligne {exc.lineno}).") from exc


# --------------------------------------------------------------------------
# Trivy
# --------------------------------------------------------------------------


def lire_trivy(chemin: str) -> tuple[dict, list[dict]]:
    """Réduit un rapport Trivy à (description du scan, liste de constats)."""
    rapport = lire_json(chemin)
    # `SchemaVersion` et `ArtifactName` sont posés par Trivy même quand il ne
    # trouve rien. Leur absence veut dire qu'on nous a donné autre chose — un
    # `{}`, un rapport d'un autre outil — et le compter pour « zéro constat »
    # serait exactement la confusion que ce script interdit.
    if not isinstance(rapport, dict) or "SchemaVersion" not in rapport or "ArtifactName" not in rapport:
        raise RapportInvalide(f"{chemin} : ce n'est pas un rapport JSON de Trivy "
                              f"(champs SchemaVersion / ArtifactName absents).")

    type_artefact = str(rapport.get("ArtifactType") or "")
    est_image = type_artefact == "container_image"
    # `filesystem` et `repository` sont tous deux un scan du dépôt.
    type_scan = "trivy-image" if est_image else "trivy-fs"
    artefact = str(rapport.get("ArtifactName") or "")
    composant_image = composant_d_image(artefact) if est_image else None
    # La « source » identifie un scan d'une collecte à l'autre. Elle ne porte
    # PAS le tag de l'image : `back:5bf1d6a2` et `back:234ab50a` sont deux états
    # successifs de la même source, et le second doit remplacer le premier dans
    # « l'état courant ».
    source = f"{type_scan}:{composant_image or 'depot'}"

    constats: list[dict] = []
    categories: set[str] = set()
    # `Results` est absent (ou `null`) d'un rapport sans rien à signaler.
    for resultat in rapport.get("Results") or []:
        cible = str(resultat.get("Target") or "")
        composant = composant_image or composant_de_chemin(cible)
        commun = {"type_scan": type_scan, "outil": "trivy", "source": source, "artefact": artefact,
                  "cible": cible, "composant": composant,
                  "classe": resultat.get("Class"), "type_cible": resultat.get("Type")}

        for vuln in resultat.get("Vulnerabilities") or []:
            categories.add("vulnerabilite")
            corrigee = (vuln.get("FixedVersion") or "").strip() or None
            constats.append({**commun, "categorie": "vulnerabilite",
                             "identifiant": vuln.get("VulnerabilityID"),
                             "severite": severite(vuln.get("Severity")),
                             "titre": vuln.get("Title") or vuln.get("VulnerabilityID"),
                             "paquet": vuln.get("PkgName"),
                             "version": vuln.get("InstalledVersion"),
                             "version_corrigee": corrigee,
                             "corrigeable": corrigee is not None,
                             "url": vuln.get("PrimaryURL")})

        for mis in resultat.get("Misconfigurations") or []:
            categories.add("misconfiguration")
            constats.append({**commun, "categorie": "misconfiguration",
                             "identifiant": mis.get("ID"),
                             # Les deux formes d'un même identifiant (`KSV-0014`
                             # et `AVD-KSV-0014`) : une exception peut citer
                             # l'une ou l'autre.
                             "_alias": [mis.get("AVDID")],
                             "severite": severite(mis.get("Severity")),
                             "titre": mis.get("Title") or mis.get("ID"),
                             "paquet": None, "version": None,
                             "version_corrigee": None, "corrigeable": None,
                             "url": mis.get("PrimaryURL")})

        for secret in resultat.get("Secrets") or []:
            categories.add("secret")
            # ⚠️ Ni `Match` ni `Code` ne sont repris : Trivy masque le secret
            # dans `Match`, mais le contexte autour suffit parfois à le
            # reconstituer. Un index sans authentification n'a pas à le porter.
            constats.append({**commun, "categorie": "secret",
                             "identifiant": secret.get("RuleID"),
                             "severite": severite(secret.get("Severity")),
                             "titre": secret.get("Title") or secret.get("RuleID"),
                             "paquet": None, "version": None,
                             "version_corrigee": None, "corrigeable": None,
                             "ligne": secret.get("StartLine"), "url": None})

    scan = {"type_scan": type_scan, "outil": "trivy", "source": source, "artefact": artefact,
            "composant": composant_image or "depot", "rapport": os.path.basename(chemin),
            "rapport_cree_le": rapport.get("CreatedAt"),
            "categories_observees": sorted(categories)}
    return scan, constats


# --------------------------------------------------------------------------
# OWASP Dependency-Check
# --------------------------------------------------------------------------


def lire_dependency_check(chemin: str) -> tuple[dict, list[dict]]:
    rapport = lire_json(chemin)
    if not isinstance(rapport, dict) or not isinstance(rapport.get("dependencies"), list):
        raise RapportInvalide(f"{chemin} : ce n'est pas un rapport JSON de Dependency-Check "
                              f"(liste `dependencies` absente).")

    projet = (rapport.get("projectInfo") or {}).get("name") or "back"
    constats: list[dict] = []
    for dependance in rapport["dependencies"]:
        vulnerabilites = dependance.get("vulnerabilities") or []
        if not vulnerabilites:
            continue
        # `pkg:maven/groupe/artefact@version` : c'est la seule forme stable du
        # nom, le `fileName` (un .jar) varie avec le cache Gradle.
        paquet, version = dependance.get("fileName"), None
        for pkg in dependance.get("packages") or []:
            trouve = re.match(r"pkg:[^/]+/(.+?)@([^?]+)", str(pkg.get("id") or ""))
            if trouve:
                paquet, version = trouve.group(1).replace("/", ":"), trouve.group(2)
                break
        for vuln in vulnerabilites:
            constats.append({"type_scan": "dependency-check", "outil": "dependency-check",
                             "source": "dependency-check:back", "artefact": projet, "cible": dependance.get("fileName"),
                             # Dependency-Check n'analyse que le back
                             # (`scanConfigurations = ['runtimeClasspath']`).
                             "composant": "back", "classe": "lang-pkgs", "type_cible": "jar",
                             "categorie": "vulnerabilite",
                             "identifiant": vuln.get("name"),
                             "severite": severite(vuln.get("severity")),
                             "titre": (vuln.get("description") or vuln.get("name") or "")[:200],
                             "paquet": paquet, "version": version,
                             # Le rapport ne donne pas de version corrigée :
                             # `null`, pas « non corrigeable ».
                             "version_corrigee": None, "corrigeable": None,
                             "url": None})

    scan = {"type_scan": "dependency-check", "outil": "dependency-check",
            "source": "dependency-check:back", "artefact": projet,
            "composant": "back", "rapport": os.path.basename(chemin),
            "rapport_cree_le": (rapport.get("projectInfo") or {}).get("reportDate"),
            "categories_observees": ["vulnerabilite"] if constats else []}
    return scan, constats


# --------------------------------------------------------------------------
# Exceptions : .trivyignore.yaml
# --------------------------------------------------------------------------


def lire_trivyignore(chemin: str) -> list[dict]:
    """Lit les entrées de `.trivyignore.yaml` sans dépendre de PyYAML.

    L'analyseur ne comprend que la forme de ce fichier : des sections de premier
    niveau, chacune une liste d'entrées `id` / `paths` / `statement` /
    `expiredAt`. Ce n'est pas un analyseur YAML, et il ne prétend pas l'être :
    une entrée sans `id` lève une erreur plutôt que d'être perdue en silence.
    """
    with open(chemin, encoding="utf-8") as fichier:
        lignes = fichier.read().splitlines()

    entrees: list[dict] = []
    section = None
    courante: dict | None = None
    cle_bloc = None      # clé dont on est en train de lire la valeur multi-ligne
    indent_cle = 0

    def valeur(texte: str) -> str:
        return texte.strip().strip("'\"")

    for brute in lignes:
        if not brute.strip() or brute.lstrip().startswith("#"):
            continue
        indent = len(brute) - len(brute.lstrip())
        ligne = brute.strip()

        if indent == 0:
            trouve = re.match(r"([A-Za-z_]+):\s*$", ligne)
            if not trouve:
                raise RapportInvalide(f"{chemin} : ligne de premier niveau inattendue : « {ligne} ».")
            section, courante, cle_bloc = trouve.group(1), None, None
            continue
        if section is None:
            raise RapportInvalide(f"{chemin} : contenu indenté avant toute section.")

        # Suite d'une valeur multi-ligne (`statement: >-`) ou d'une liste
        # (`paths:`) : tout ce qui est plus indenté que la clé lui appartient.
        if cle_bloc and courante is not None and indent > indent_cle:
            if cle_bloc == "paths":
                if ligne.startswith("- "):
                    courante["paths"].append(valeur(ligne[2:]))
            else:
                courante[cle_bloc] = (courante.get(cle_bloc, "") + " " + ligne).strip()
            continue
        cle_bloc = None

        if ligne.startswith("- "):
            courante = {"section": section, "paths": []}
            entrees.append(courante)
            ligne = ligne[2:].strip()
            indent += 2
        if courante is None:
            raise RapportInvalide(f"{chemin} : « {ligne} » hors de toute entrée.")

        trouve = re.match(r"([A-Za-z_]+):\s*(.*)$", ligne)
        if not trouve:
            raise RapportInvalide(f"{chemin} : ligne non comprise : « {ligne} ».")
        cle, reste = trouve.group(1), trouve.group(2).strip()
        if cle == "paths" or reste in ("", ">", ">-", "|", "|-"):
            cle_bloc, indent_cle = cle, indent
            if cle != "paths":
                courante[cle] = ""
        else:
            courante[cle] = valeur(reste)

    for entree in entrees:
        if not entree.get("id"):
            raise RapportInvalide(f"{chemin} : une entrée de « {entree['section']} » n'a pas d'`id`.")
    return entrees


def forme_canonique(identifiant) -> str:
    """`AVD-KSV-0014`, `KSV-0014` et `KSV014` désignent la même règle."""
    texte = str(identifiant or "").upper()
    texte = re.sub(r"^AVD-", "", texte)
    trouve = re.match(r"^([A-Z]+)-?0*(\d+)$", texte)
    return f"{trouve.group(1)}-{int(trouve.group(2))}" if trouve else texte


def chemin_couvert(cible: str, chemins: list[str]) -> bool:
    # Une entrée sans `paths` vaut pour tout le dépôt, comme dans Trivy.
    if not chemins:
        return True
    propre = (cible or "").lstrip("./")
    return any(propre == c.lstrip("./") for c in chemins)


def appliquer_exceptions(constats: list[dict], exceptions: list[dict], jour: date) -> None:
    """Pose `statut` sur chaque constat, et compte ce que couvre chaque exception."""
    for exception in exceptions:
        exception["_couverts"] = 0
    for constat in constats:
        constat["statut"] = "ouvert"
        candidats = {forme_canonique(constat.get("identifiant"))}
        candidats.update(forme_canonique(a) for a in constat.get("_alias", []) if a)
        for exception in exceptions:
            if SECTIONS_TRIVYIGNORE.get(exception["section"]) != constat["categorie"]:
                continue
            if forme_canonique(exception["id"]) not in candidats:
                continue
            if not chemin_couvert(constat.get("cible") or "", exception["paths"]):
                continue
            # Une exception échue ne couvre plus rien : c'est le comportement de
            # Trivy, et c'est tout l'intérêt d'une date d'expiration.
            echeance = parse_jour(exception.get("expiredAt"))
            if echeance and echeance < jour:
                continue
            constat["statut"] = "excepte"
            exception["_couverts"] += 1
            break


def parse_jour(valeur) -> date | None:
    try:
        return date.fromisoformat(str(valeur)[:10]) if valeur else None
    except ValueError:
        return None


def documents_exceptions(exceptions: list[dict], jour: date, horodatage: str,
                         rapports_lus: bool) -> list[dict]:
    documents = []
    for exception in exceptions:
        echeance = parse_jour(exception.get("expiredAt"))
        documents.append({
            "@timestamp": horodatage, "type": "exception",
            "categorie": SECTIONS_TRIVYIGNORE.get(exception["section"], exception["section"]),
            "identifiant": exception["id"],
            "chemin": ", ".join(exception["paths"]) or "(tout le dépôt)",
            "composant": composant_de_chemin(exception["paths"][0]) if exception["paths"] else "depot",
            # Une exception sans échéance est permise par Trivy. `null`, et un
            # drapeau à part : « pas de date » n'est ni « expirée » ni « valide
            # pour 0 jour ».
            "echeance": echeance.isoformat() if echeance else None,
            "sans_echeance": echeance is None,
            "jours_restants": (echeance - jour).days if echeance else None,
            "expiree": bool(echeance and echeance < jour),
            "justification": (exception.get("statement") or "")[:300],
            # Sans rapport lu, on ne sait pas ce que l'exception couvre : `null`.
            "constats_couverts": exception.get("_couverts", 0) if rapports_lus else None,
        })
    return documents


# --------------------------------------------------------------------------
# Assemblage
# --------------------------------------------------------------------------


def commit_courant(argument: str | None) -> str | None:
    if argument:
        return argument
    if os.environ.get("CI_COMMIT_SHA"):
        return os.environ["CI_COMMIT_SHA"]
    try:
        sortie = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True,
                                text=True, timeout=10, check=False)
        return sortie.stdout.strip() or None if sortie.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def decompte(constats: list[dict]) -> dict:
    """Décompte par sévérité, les cinq clés toujours présentes.

    Ici un 0 est bien une mesure : le rapport a été lu en entier.
    """
    ouverts = [c for c in constats if c["statut"] == "ouvert"]
    return {
        "total": len(constats),
        "ouverts": len(ouverts),
        "exceptes": len(constats) - len(ouverts),
        # La somme que la porte bloquante du pipeline regarde (`--severity
        # HIGH,CRITICAL`), précalculée : une courbe Kibana ne sait pas
        # additionner deux champs sans formule.
        "hauts_critiques": sum(1 for c in ouverts if c["severite"] in ("CRITICAL", "HIGH")),
        "par_severite": {s: sum(1 for c in ouverts if c["severite"] == s) for s in SEVERITES},
        "par_categorie": {k: sum(1 for c in ouverts if c["categorie"] == k)
                          for k in ("vulnerabilite", "misconfiguration", "secret")},
    }


def identifiant_document(constat: dict, commit: str | None, jour: str) -> str:
    # Déterministe : même commit + même constat = même document. Sans commit, le
    # jour sert de repli, pour qu'une collecte quotidienne ne s'empile pas.
    base = "|".join(str(constat.get(k) or "") for k in
                    ("type_scan", "artefact", "cible", "categorie", "identifiant",
                     "paquet", "version", "ligne"))
    empreinte = hashlib.sha1(base.encode("utf-8")).hexdigest()[:16]
    return f"{commit[:8] if commit else jour}-{constat['type_scan']}-{empreinte}"


def construire_rapport(scans: list[tuple[dict, list[dict]]], exceptions: list[dict] | None,
                       commit: str | None, ref: str | None, maintenant: datetime) -> dict:
    horodatage = iso(maintenant)
    jour = maintenant.date()
    tous = [c for _, constats in scans for c in constats]
    appliquer_exceptions(tous, exceptions or [], jour)

    contexte = {"@timestamp": horodatage, "commit": (commit or "")[:8] or None,
                "ref": ref, "courant": True}
    documents_scans, documents_constats = [], []
    deja_vus: dict[str, int] = {}
    for scan, constats in scans:
        chiffres = decompte(constats)
        documents_scans.append({**contexte, "type": "scan", **scan, **chiffres})
        for constat in constats:
            doc = {k: v for k, v in constat.items() if not k.startswith("_")}
            doc["severite_rang"] = RANG[doc["severite"]]
            # Trivy signale parfois deux fois la même règle sur le même fichier
            # (un constat par conteneur d'un même manifeste, par exemple). Sans
            # ce rang, les deux auraient le même `_id` : le second écraserait
            # le premier, et l'index compterait moins de constats que le scan.
            cle = identifiant_document(constat, commit, jour.isoformat())
            deja_vus[cle] = deja_vus.get(cle, 0) + 1
            doc["_id"] = cle if deja_vus[cle] == 1 else f"{cle}-{deja_vus[cle]}"
            documents_constats.append({**contexte, "type": "constat", **doc})

    # Tri stable et lisible dans la sortie JSON : le plus grave d'abord.
    documents_constats.sort(key=lambda d: (-d["severite_rang"], str(d.get("identifiant"))))

    return {
        "genere_le": horodatage,
        "commit": contexte["commit"],
        "ref": ref,
        "sources": [s["rapport"] for s, _ in scans],
        # Le total n'existe que s'il y a eu au moins un rapport : sans scan, il
        # n'y a pas « zéro vulnérabilité », il n'y a pas de mesure.
        "resume": decompte(tous) if scans else None,
        "scans": documents_scans,
        "constats": documents_constats,
        "exceptions": (documents_exceptions(exceptions, jour, horodatage, bool(scans))
                       if exceptions is not None else None),
    }


# --------------------------------------------------------------------------
# Elasticsearch
# --------------------------------------------------------------------------


def documents_bulk(rapport: dict, index: str) -> str:
    """Prépare le corps NDJSON de l'API _bulk, `_id` déterministes compris."""
    prefixe = (rapport["commit"] or rapport["genere_le"][:10])
    lignes = []

    def ajouter(identifiant: str, doc: dict) -> None:
        lignes.append(json.dumps({"index": {"_index": index, "_id": identifiant}}))
        lignes.append(json.dumps(doc, ensure_ascii=False))

    for scan in rapport["scans"]:
        ajouter(f"scan-{prefixe}-{scan['source']}", scan)
    for constat in rapport["constats"]:
        ajouter(constat["_id"], {k: v for k, v in constat.items() if k != "_id"})
    # Les exceptions n'ont pas d'histoire à garder : un seul document par
    # entrée, réécrit à chaque collecte avec les jours restants du jour.
    for exception in rapport["exceptions"] or []:
        cle = hashlib.sha1(f"{exception['identifiant']}|{exception['chemin']}".encode()).hexdigest()[:12]
        ajouter(f"exception-{cle}", exception)
    return "\n".join(lignes) + "\n" if lignes else ""


def requete_es(url: str, corps: bytes, type_contenu: str) -> dict:
    requete = urllib.request.Request(url, data=corps, method="POST")
    requete.add_header("Content-Type", type_contenu)
    with urllib.request.urlopen(requete, timeout=60) as reponse:
        return json.loads(reponse.read().decode())


def envoyer_elasticsearch(url: str, index: str, rapport: dict) -> bool:
    base = url.rstrip("/")
    corps = documents_bulk(rapport, index).encode("utf-8")
    if not corps:
        log("Aucun document à envoyer.")
        return True
    try:
        # 1. Les documents déjà indexés pour les mêmes sources ne sont plus
        #    « l'état courant ». On ne touche QUE les sources relues : un scan
        #    d'image absent aujourd'hui garde son dernier état connu au lieu de
        #    disparaître du tableau de bord.
        sources = sorted({s["source"] for s in rapport["scans"]})
        if sources:
            # `match_phrase` plutôt que `term` : le mapping est dynamique, donc
            # `source` est un champ texte doublé d'un `.keyword`. La phrase
            # exacte marche sur les deux, quel que soit le mapping en place.
            requete = {"query": {"bool": {"filter": [{"term": {"courant": True}}],
                                          "should": [{"match_phrase": {"source": s}} for s in sources],
                                          "minimum_should_match": 1}},
                       "script": {"source": "ctx._source.courant = false", "lang": "painless"}}
            # `ignore_unavailable` : à la toute première collecte l'index
            # n'existe pas encore, et ce n'est pas une erreur.
            reponse = requete_es(f"{base}/{index}/_update_by_query?refresh=true&conflicts=proceed"
                                 f"&ignore_unavailable=true",
                                 json.dumps(requete).encode(), "application/json")
            log(f"{reponse.get('updated', 0)} ancien(s) document(s) passé(s) à courant=false.")

        # 2. Purge des exceptions : ce jeu est remplacé en entier, sinon une
        #    entrée retirée de .trivyignore.yaml resterait affichée à jamais.
        if rapport["exceptions"] is not None:
            requete_es(f"{base}/{index}/_delete_by_query?refresh=true&conflicts=proceed"
                       f"&ignore_unavailable=true",
                       json.dumps({"query": {"match_phrase": {"type": "exception"}}}).encode(),
                       "application/json")

        reponse = requete_es(f"{base}/_bulk?refresh=true", corps, "application/x-ndjson")
    except urllib.error.HTTPError as exc:
        log(f"ERREUR : Elasticsearch a répondu {exc.code} ({exc.reason}).")
        return False
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        log(f"ERREUR : envoi Elasticsearch impossible : {exc}")
        return False

    # _bulk répond 200 même quand des documents ont été rejetés : le seul moyen
    # de savoir si l'indexation a marché est de relire le drapeau "errors".
    if reponse.get("errors"):
        refus = [item for action in reponse.get("items", [])
                 for item in action.values() if item.get("error")]
        log(f"ERREUR : {len(refus)} document(s) refusé(s) par Elasticsearch.")
        if refus:
            log(f"  → premier refus : {refus[0].get('error')}")
        return False
    log(f"{len(reponse.get('items', []))} document(s) indexé(s) dans « {index} ».")
    return True


# --------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transforme les rapports Trivy / Dependency-Check en documents Elasticsearch.",
        epilog="Un rapport absent ne produit aucun zéro ; un rapport invalide est une erreur.")
    parser.add_argument("--trivy-report", action="append", default=[], metavar="CHEMIN",
                        help="Rapport JSON de Trivy (fs ou image). Répétable.")
    parser.add_argument("--dependency-check-report", action="append", default=[], metavar="CHEMIN",
                        help="Rapport JSON d'OWASP Dependency-Check. Répétable.")
    parser.add_argument("--optional", action="store_true",
                        help="Un rapport introuvable est ignoré avec un avertissement.")
    parser.add_argument("--trivyignore", default=None, metavar="CHEMIN",
                        help=f"Fichier d'exceptions (défaut : {DEFAULT_TRIVYIGNORE} s'il existe).")
    parser.add_argument("--no-trivyignore", action="store_true", help="Ne lit aucune exception.")
    parser.add_argument("--commit", default=None, help="Commit scanné (défaut : $CI_COMMIT_SHA, puis git).")
    parser.add_argument("--ref", default=None, help="Branche ou tag (défaut : $CI_COMMIT_REF_NAME).")
    parser.add_argument("--date", default=None, help="Horodatage ISO 8601 des documents (défaut : maintenant).")
    parser.add_argument("--output", default=None, help="Fichier de sortie (défaut : stdout).")
    parser.add_argument("--elasticsearch", default=None, help="URL d'un Elasticsearch (API _bulk).")
    parser.add_argument("--es-index", default=DEFAULT_ES_INDEX, help="Index Elasticsearch.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if args.date:
        try:
            maintenant = datetime.fromisoformat(args.date.replace("Z", "+00:00"))
        except ValueError:
            log(f"ERREUR : --date « {args.date} » n'est pas une date ISO 8601.")
            return 1
        if maintenant.tzinfo is None:
            maintenant = maintenant.replace(tzinfo=timezone.utc)
    else:
        maintenant = datetime.now(timezone.utc)

    # --- Les exceptions -----------------------------------------------------
    exceptions = None
    if not args.no_trivyignore:
        chemin = args.trivyignore or (DEFAULT_TRIVYIGNORE if os.path.isfile(DEFAULT_TRIVYIGNORE) else None)
        if chemin:
            try:
                exceptions = lire_trivyignore(chemin)
            except (OSError, RapportInvalide) as exc:
                log(f"ERREUR : fichier d'exceptions illisible : {exc}")
                return 1
            log(f"{len(exceptions)} exception(s) lue(s) dans {chemin}.")

    # --- Les rapports -------------------------------------------------------
    demandes = ([(chemin, lire_trivy) for chemin in args.trivy_report]
                + [(chemin, lire_dependency_check) for chemin in args.dependency_check_report])
    if not demandes and exceptions is None:
        log("ERREUR : aucune source. Fournir au moins --trivy-report, "
            "--dependency-check-report ou un fichier d'exceptions.")
        return 1

    scans: list[tuple[dict, list[dict]]] = []
    for chemin, lecteur in demandes:
        if not os.path.isfile(chemin):
            if args.optional:
                # Dit explicitement : ce scan n'a pas de mesure, et le tableau
                # de bord n'en recevra aucune — surtout pas un zéro.
                log(f"Rapport absent, ignoré (--optional) : {chemin}. Aucune mesure pour ce scan.")
                continue
            log(f"ERREUR : rapport introuvable : {chemin}")
            return 1
        try:
            scans.append(lecteur(chemin))
        except (OSError, RapportInvalide) as exc:
            log(f"ERREUR : {exc}")
            return 1

    rapport = construire_rapport(scans, exceptions, commit_courant(args.commit),
                                 args.ref or os.environ.get("CI_COMMIT_REF_NAME") or None,
                                 maintenant)

    for scan in rapport["scans"]:
        detail = ", ".join(f"{s} {n}" for s, n in scan["par_severite"].items())
        log(f"{scan['type_scan']} ({scan['artefact']}) : {scan['ouverts']} constat(s) ouvert(s) "
            f"[{detail}], {scan['exceptes']} excepté(s).")
    if not rapport["scans"]:
        log("Aucun rapport de scan lu : aucun décompte produit (ce n'est pas un zéro).")
    for exception in rapport["exceptions"] or []:
        if exception["expiree"]:
            log(f"⚠️ Exception échue depuis le {exception['echeance']} : "
                f"{exception['identifiant']} ({exception['chemin']}).")

    sortie = json.dumps(rapport, ensure_ascii=False, indent=2)
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as fichier:
                fichier.write(sortie + "\n")
        except OSError as exc:
            log(f"ERREUR : écriture impossible dans {args.output} : {exc}")
            return 1
        log(f"Rapport écrit dans {args.output}.")
    else:
        print(sortie)

    if args.elasticsearch and not envoyer_elasticsearch(args.elasticsearch, args.es_index, rapport):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
