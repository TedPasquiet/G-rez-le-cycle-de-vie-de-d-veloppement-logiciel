#!/usr/bin/env python3
"""install_alerting.py

Ce script installe (ou réinstalle) l'alerting de la stack de supervision :
le modèle de l'index `microcrm-alerts` dans Elasticsearch, puis les règles
d'alerte Kibana décrites dans `k8s/elk/alerting/rules/`.

Le manque qu'il comble : une règle créée à la souris dans Kibana vit dans
l'index `.kibana` d'un pod. Elle disparaît avec le PVC, avec le namespace, avec
un `minikube delete` — et une alerte qui a disparu ne prévient pas qu'elle a
disparu. Ici la règle est un fichier, et ce script est la seule façon prévue de
la faire exister dans une instance.

Comment ça marche :
    Un fichier JSON par règle. Le NOM DU FICHIER (sans `.json`) est
    l'identifiant de la règle dans Kibana, et son contenu est exactement le
    corps attendu par `POST /api/alerting/rule/<id>`. C'est cet identifiant
    choisi, et non tiré au hasard par Kibana, qui rend le script idempotent :
    règle absente -> création ; règle présente -> mise à jour sur place. Le
    relancer dix fois donne toujours huit règles, jamais quatre-vingts.

Trois modes :
    (sans option)  Installe le modèle d'index puis les règles. Parle à Kibana
                   et à Elasticsearch par HTTP : il faut les deux
                   `port-forward` (voir k8s/elk/alerting/README.md).
    --secret       Crée le Secret Kubernetes qui porte la clé de chiffrement de
                   Kibana s'il n'existe pas, puis redémarre Kibana. Parle à
                   kubectl, pas à Kibana. À faire UNE fois par cluster, avant
                   l'installation des règles.
    --dry-run      Relit et contrôle les fichiers de règles, sans aucun appel
                   réseau. C'est le mode qu'utilisent les tests.
    --etat         Affiche l'état de chaque règle dans Kibana (dernière
                   exécution, alerte active ou non). Ne modifie rien.

Pourquoi `--secret` est un mode à part et pas une étape automatique :
    Redémarrer Kibana coupe le `port-forward` par lequel on lui parle. Un
    script qui ferait les deux d'un trait échouerait toujours à la seconde
    moitié. Les deux étapes sont donc séparées, et l'installation refuse de
    continuer tant que la clé n'est pas en place — avec un message qui dit
    quoi lancer.

Pourquoi la clé n'est pas dans le dépôt :
    Kibana chiffre une partie des règles et des connecteurs. Sans clé
    PERMANENTE il en tire une au hasard à chaque démarrage, et l'API des
    connecteurs répond 500. Cette clé est un secret et le dépôt est public :
    elle est tirée au hasard ici, envoyée à kubectl par l'entrée standard
    (jamais en argument, un argument se lit dans `ps`), et n'est écrite nulle
    part ailleurs que dans le Secret.

Variables d'environnement lues :
    KIBANA_URL          défaut http://127.0.0.1:5601
    ELASTICSEARCH_URL   défaut http://127.0.0.1:9200
    LOGGING_NAMESPACE   défaut logging (mode --secret)

Ce que renvoie le script :
    0 = tout est en place (ou, en --dry-run, tous les fichiers sont valides)
    1 = un fichier de règle est invalide, Kibana ou Elasticsearch est
        injoignable, la clé de chiffrement manque, ou un appel a été refusé
    2 = erreur d'utilisation (renvoyée par argparse)

Exemples :
    scripts/monitoring/install_alerting.py --secret
    scripts/monitoring/install_alerting.py
    scripts/monitoring/install_alerting.py --etat
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

RACINE = Path(__file__).resolve().parents[2]
DOSSIER_ALERTING = RACINE / "k8s" / "elk" / "alerting"
KIBANA_CONFIG = RACINE / "k8s" / "elk" / "kibana-config.yaml"

NOM_SECRET = "kibana-encryption-key"
CLE_SECRET = "encryptionKey"
NOM_MODELE = "microcrm-alerts"

# Le critère que cet alerting doit satisfaire nomme trois familles. Le contrôle
# est fait ici, sur les fichiers, pour qu'une règle supprimée par mégarde fasse
# échouer les tests plutôt que de laisser une famille sans surveillance.
FAMILLES = ("disponibilite", "performance", "securite")

# Champs que Kibana refuse dans le corps d'une MISE À JOUR (PUT) alors qu'il
# les exige à la création (POST) : le type et le propriétaire d'une règle sont
# immuables, et l'activation passe par deux routes à part.
CHAMPS_CREATION_SEULE = ("rule_type_id", "consumer", "enabled")


class Echec(Exception):
    """Erreur attendue : son message suffit, la pile d'appels n'apporte rien."""


def journal(message: str) -> None:
    print(message, flush=True)


# --------------------------------------------------------------------------
# Lecture et contrôle des fichiers de règles
# --------------------------------------------------------------------------


def famille_de(regle: dict) -> str | None:
    """La famille est portée par une étiquette `famille:<nom>` de la règle."""
    for etiquette in regle.get("tags", []):
        if isinstance(etiquette, str) and etiquette.startswith("famille:"):
            return etiquette.split(":", 1)[1]
    return None


def connecteurs_declares() -> set[str] | None:
    """Identifiants des connecteurs préconfigurés dans kibana-config.yaml.

    Lecture volontairement naïve (pas de dépendance à PyYAML, même règle que
    le reste de scripts/) : sous `xpack.actions.preconfigured:`, les clés
    situées exactement un cran plus à droite sont les identifiants.
    Renvoie None si le fichier est illisible : le contrôle est alors sauté
    plutôt que de faire échouer une validation pour une raison étrangère.
    """
    try:
        lignes = KIBANA_CONFIG.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    identifiants: set[str] = set()
    retrait_bloc = None
    for ligne in lignes:
        nue = ligne.strip()
        if not nue or nue.startswith("#"):
            continue
        retrait = len(ligne) - len(ligne.lstrip())
        if nue == "xpack.actions.preconfigured:":
            retrait_bloc = retrait
            continue
        if retrait_bloc is None:
            continue
        if retrait <= retrait_bloc:
            break
        if retrait == retrait_bloc + 2 and nue.endswith(":"):
            identifiants.add(nue[:-1])
    return identifiants


def charger_regles(dossier: Path) -> dict[str, dict]:
    """Relit tous les fichiers de règles et s'arrête au premier défaut."""
    fichiers = sorted(dossier.glob("*.json"))
    if not fichiers:
        raise Echec(f"aucun fichier de règle dans {dossier}")

    connus = connecteurs_declares()
    regles: dict[str, dict] = {}
    for fichier in fichiers:
        try:
            regle = json.loads(fichier.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as erreur:
            raise Echec(f"{fichier.name} : JSON illisible ({erreur})") from erreur
        if not isinstance(regle, dict):
            raise Echec(f"{fichier.name} : un objet JSON est attendu")

        manquants = [
            champ
            for champ in ("name", "rule_type_id", "consumer", "schedule", "params", "actions")
            if champ not in regle
        ]
        if manquants:
            raise Echec(f"{fichier.name} : champ(s) manquant(s) : {', '.join(manquants)}")

        famille = famille_de(regle)
        if famille not in FAMILLES:
            raise Echec(
                f"{fichier.name} : étiquette `famille:` absente ou inconnue "
                f"(attendu : {', '.join(FAMILLES)})"
            )

        # Une règle sans action s'évalue, passe « active » dans Kibana… et ne
        # prévient personne. C'est le défaut le plus silencieux possible.
        if not regle["actions"]:
            raise Echec(f"{fichier.name} : aucune action, la règle ne préviendrait personne")
        if connus is not None:
            for action in regle["actions"]:
                if action.get("id") not in connus:
                    raise Echec(
                        f"{fichier.name} : connecteur '{action.get('id')}' absent de "
                        f"{KIBANA_CONFIG.name} (déclarés : {', '.join(sorted(connus)) or 'aucun'})"
                    )
        regles[fichier.stem] = regle

    couvertes = {famille_de(regle) for regle in regles.values()}
    absentes = [famille for famille in FAMILLES if famille not in couvertes]
    if absentes:
        raise Echec(f"famille(s) sans aucune règle : {', '.join(absentes)}")
    return regles


def afficher_regles(regles: dict[str, dict]) -> None:
    for identifiant, regle in regles.items():
        journal(f"  {famille_de(regle):<14} {identifiant:<30} {regle['name']}")
    journal(f"{len(regles)} règle(s) valide(s), {len(FAMILLES)} familles couvertes")


# --------------------------------------------------------------------------
# HTTP — urllib, sans dépendance (même règle que scripts/ci/notify.py)
# --------------------------------------------------------------------------


def appel(methode: str, url: str, corps: dict | None = None) -> tuple[int, dict]:
    """Renvoie (code HTTP, corps décodé). Lève Echec si le serveur ne répond pas.

    Un code 4xx/5xx n'est PAS une exception ici : l'appelant a besoin de
    distinguer « la règle n'existe pas » (404, normal) de « refusée » (400).
    """
    donnees = json.dumps(corps).encode("utf-8") if corps is not None else None
    requete = urllib.request.Request(url, data=donnees, method=methode)
    requete.add_header("Content-Type", "application/json")
    # Kibana refuse toute écriture sans cet en-tête (protection XSRF).
    requete.add_header("kbn-xsrf", "true")
    try:
        with urllib.request.urlopen(requete, timeout=30) as reponse:
            brut = reponse.read()
            code = reponse.status
    except urllib.error.HTTPError as erreur:
        brut = erreur.read()
        code = erreur.code
    except (urllib.error.URLError, OSError) as erreur:
        raise Echec(
            f"{url} est injoignable ({erreur}). Les deux port-forward sont-ils ouverts ? "
            "Voir k8s/elk/alerting/README.md."
        ) from erreur
    try:
        return code, json.loads(brut) if brut else {}
    except json.JSONDecodeError:
        return code, {"message": brut.decode("utf-8", "replace")[:300]}


def exiger(code: int, corps: dict, contexte: str) -> dict:
    if code >= 400:
        raise Echec(f"{contexte} : HTTP {code} — {corps.get('message') or corps.get('error') or corps}")
    return corps


# --------------------------------------------------------------------------
# Les trois modes
# --------------------------------------------------------------------------


def installer(regles: dict[str, dict], kibana: str, elasticsearch: str) -> None:
    sante = exiger(*appel("GET", f"{kibana}/api/alerting/_health"), "état de l'alerting Kibana")
    if not sante.get("has_permanent_encryption_key"):
        raise Echec(
            "Kibana n'a pas de clé de chiffrement permanente : les règles ne survivraient pas "
            "à son redémarrage. Lancer d'abord : scripts/monitoring/install_alerting.py --secret"
        )

    presents = {
        connecteur.get("id")
        for connecteur in exiger(*appel("GET", f"{kibana}/api/actions/connectors"), "liste des connecteurs")
    }
    attendus = {action["id"] for regle in regles.values() for action in regle["actions"]}
    if attendus - presents:
        raise Echec(
            f"connecteur(s) absent(s) de Kibana : {', '.join(sorted(attendus - presents))}. "
            "k8s/elk/kibana-config.yaml a-t-il été appliqué, et Kibana redémarré depuis ?"
        )

    # Le modèle AVANT les règles : la première alerte crée l'index, et un index
    # créé sans modèle typerait `valeur` en texte — plus aucun graphique
    # possible dessus, et un type ne se corrige pas après coup.
    modele = json.loads((DOSSIER_ALERTING / "index-template.json").read_text(encoding="utf-8"))
    exiger(
        *appel("PUT", f"{elasticsearch}/_index_template/{NOM_MODELE}", modele),
        f"modèle d'index {NOM_MODELE}",
    )
    journal(f"modèle d'index {NOM_MODELE} : en place")

    for identifiant, regle in regles.items():
        url = f"{kibana}/api/alerting/rule/{identifiant}"
        code, existante = appel("GET", url)
        if code == 404:
            exiger(*appel("POST", url, regle), f"création de {identifiant}")
            journal(f"règle {identifiant} : créée")
            continue
        exiger(code, existante, f"lecture de {identifiant}")
        mise_a_jour = {cle: valeur for cle, valeur in regle.items() if cle not in CHAMPS_CREATION_SEULE}
        exiger(*appel("PUT", url, mise_a_jour), f"mise à jour de {identifiant}")
        voulue = regle.get("enabled", True)
        if existante.get("enabled") != voulue:
            exiger(*appel("POST", f"{url}/{'_enable' if voulue else '_disable'}"), f"activation de {identifiant}")
        journal(f"règle {identifiant} : mise à jour")

    # Une règle étiquetée `microcrm` qui n'a plus de fichier est signalée, pas
    # supprimée : ce script ne détruit rien qu'il n'ait pas sous les yeux.
    _, trouvees = appel("GET", f"{kibana}/api/alerting/rules/_find?per_page=100")
    for orpheline in trouvees.get("data", []):
        if "microcrm" in orpheline.get("tags", []) and orpheline.get("id") not in regles:
            journal(f"attention : la règle {orpheline.get('id')} existe dans Kibana sans fichier dans le dépôt")
    journal(f"{len(regles)} règle(s) en place")


def etat(regles: dict[str, dict], kibana: str) -> None:
    absentes = 0
    for identifiant in regles:
        code, regle = appel("GET", f"{kibana}/api/alerting/rule/{identifiant}")
        if code == 404:
            journal(f"  {identifiant:<30} ABSENTE de Kibana")
            absentes += 1
            continue
        exiger(code, regle, f"lecture de {identifiant}")
        execution = regle.get("execution_status", {})
        derniere = regle.get("last_run") or {}
        journal(
            f"  {identifiant:<30} activée={str(regle.get('enabled')).lower():<5} "
            f"état={execution.get('status', '?'):<8} dernière exécution={derniere.get('outcome', '?'):<9} "
            f"alertes actives={(derniere.get('alerts_count') or {}).get('active', '?')}"
        )
    if absentes:
        raise Echec(f"{absentes} règle(s) du dépôt absente(s) de Kibana : relancer l'installation")


def creer_secret(espace: str) -> None:
    def kubectl(*arguments: str, entree: str | None = None) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(
                ["kubectl", "-n", espace, *arguments],
                input=entree, capture_output=True, text=True, check=False,
            )
        except FileNotFoundError as erreur:
            raise Echec("kubectl est introuvable dans le PATH") from erreur

    if kubectl("get", "secret", NOM_SECRET).returncode == 0:
        # Surtout ne pas la régénérer : une nouvelle clé rendrait illisibles
        # les règles chiffrées avec l'ancienne.
        journal(f"le Secret {NOM_SECRET} existe déjà dans {espace} : rien à faire")
        return

    # 64 caractères hexadécimaux : Kibana en exige au moins 32.
    # `--from-file=…=/dev/stdin` : la clé passe par l'entrée standard, donc
    # n'apparaît ni dans la liste des processus ni dans l'historique du shell.
    creation = kubectl(
        "create", "secret", "generic", NOM_SECRET,
        f"--from-file={CLE_SECRET}=/dev/stdin",
        entree=secrets.token_hex(32),
    )
    if creation.returncode != 0:
        raise Echec(f"création du Secret {NOM_SECRET} refusée : {creation.stderr.strip()}")
    journal(f"Secret {NOM_SECRET} créé dans {espace} (clé aléatoire, non affichée)")

    # Une variable d'environnement tirée d'un Secret n'est lue qu'au démarrage
    # du conteneur : sans redémarrage, Kibana continuerait avec sa clé jetable.
    for arguments in (("rollout", "restart", "deployment/kibana"),
                      ("rollout", "status", "deployment/kibana", "--timeout=420s")):
        resultat = kubectl(*arguments)
        if resultat.returncode != 0:
            raise Echec(f"kubectl {' '.join(arguments)} a échoué : {resultat.stderr.strip()}")
    journal("Kibana redémarré. Rouvrir le port-forward de Kibana avant d'installer les règles.")


def main() -> int:
    analyseur = argparse.ArgumentParser(description="Installe l'alerting Kibana de MicroCRM.")
    modes = analyseur.add_mutually_exclusive_group()
    modes.add_argument("--secret", action="store_true", help="crée le Secret de la clé de chiffrement, puis redémarre Kibana")
    modes.add_argument("--dry-run", action="store_true", help="contrôle les fichiers de règles sans aucun appel réseau")
    modes.add_argument("--etat", action="store_true", help="affiche l'état des règles dans Kibana")
    analyseur.add_argument("--regles", type=Path, default=DOSSIER_ALERTING / "rules", help="dossier des fichiers de règles")
    options = analyseur.parse_args()

    kibana = os.environ.get("KIBANA_URL", "http://127.0.0.1:5601").rstrip("/")
    elasticsearch = os.environ.get("ELASTICSEARCH_URL", "http://127.0.0.1:9200").rstrip("/")

    try:
        if options.secret:
            creer_secret(os.environ.get("LOGGING_NAMESPACE", "logging"))
            return 0
        regles = charger_regles(options.regles)
        if options.dry_run:
            afficher_regles(regles)
        elif options.etat:
            etat(regles, kibana)
        else:
            installer(regles, kibana, elasticsearch)
    except Echec as erreur:
        print(f"ERREUR : {erreur}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
