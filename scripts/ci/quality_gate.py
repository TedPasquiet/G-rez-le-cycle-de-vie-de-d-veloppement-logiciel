#!/usr/bin/env python3
"""quality_gate.py

Ce script va demander à SonarCloud si le "Quality Gate" du projet est passé ou
non, et fait échouer le pipeline si ce n'est pas le cas. Le Quality Gate, c'est
l'ensemble des règles de Sonar (bugs, failles, couverture de tests...). Sonar
sait déjà tout ça, mais ici on récupère le résultat pour bloquer la CI.

Comment ça marche :
    L'analyse Sonar prend un peu de temps, donc le script appelle l'API
    plusieurs fois jusqu'à avoir le résultat (c'est ce qu'on appelle du polling).
    Ensuite :
        - il renvoie 0 si c'est bon (statut OK),
        - il renvoie 2 si le Quality Gate est en échec (et affiche pourquoi),
        - il renvoie 1 s'il y a un souci technique (réseau, token, trop long).
    J'utilise seulement des modules de base de Python, comme ça il n'y a rien à
    installer.

Les options :
    --project-key KEY   La clé du projet dans SonarCloud (obligatoire).
    --host URL          L'adresse de Sonar. Par défaut : https://sonarcloud.io
    --branch NAME       La branche analysée (facultatif).
    --timeout SECONDS   Temps max d'attente du résultat. Par défaut : 300
    --poll SECONDS      Temps entre 2 essais. Par défaut : 10

Variable d'environnement :
    SONAR_TOKEN         Le token Sonar (obligatoire, jamais affiché dans les logs).

Ce que renvoie le script :
    0 = Quality Gate OK · 1 = souci technique · 2 = Quality Gate en échec

Exemple :
    SONAR_TOKEN=$SONAR_TOKEN scripts/ci/quality_gate.py \
        --project-key pasquietted_mon-projet --branch "$CI_COMMIT_REF_NAME"
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


# Le script est lancé une fois par projet Sonar (back, puis front). Sans ce
# préfixe, impossible de savoir laquelle des deux exécutions a produit un log.
_CONTEXT = ""


def log(message: str) -> None:
    """Petit helper pour afficher un message (sur stderr pour rester propre)."""
    scope = f" {_CONTEXT}" if _CONTEXT else ""
    print(f"[quality_gate{scope}] {message}", file=sys.stderr, flush=True)


def describe_http_error(exc: urllib.error.HTTPError) -> str:
    """Extrait le message d'erreur renvoyé par Sonar dans le corps de la réponse.

    `exc.reason` ne donne que le libellé HTTP générique ("Forbidden"), ce qui ne
    dit pas *pourquoi*. Sonar, lui, répond un JSON du type
    {"errors": [{"msg": "Insufficient privileges"}]} : c'est ça qu'on veut voir.
    """
    try:
        body = exc.read().decode(errors="replace").strip()
    except Exception:  # noqa: BLE001 - le corps est optionnel, on ne masque rien d'utile
        return str(exc.reason)

    if not body:
        return str(exc.reason)

    try:
        errors = json.loads(body).get("errors", [])
        messages = [e.get("msg", "") for e in errors if e.get("msg")]
        if messages:
            return " | ".join(messages)
    except (json.JSONDecodeError, AttributeError):
        pass

    # Corps non JSON (page HTML d'un proxy, par exemple) : on tronque.
    return body[:500]


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vérifie le Quality Gate SonarCloud.")
    parser.add_argument("--project-key", required=True, help="Clé du projet SonarCloud.")
    parser.add_argument("--host", default="https://sonarcloud.io", help="Hôte Sonar.")
    parser.add_argument("--branch", default=None, help="Branche analysée (optionnel).")
    parser.add_argument("--timeout", type=int, default=300, help="Attente max en secondes.")
    parser.add_argument("--poll", type=int, default=10, help="Intervalle de polling en secondes.")
    return parser.parse_args(argv)


def build_request(host: str, project_key: str, branch: str | None, token: str) -> urllib.request.Request:
    """Prépare l'appel à l'API Sonar (URL + authentification avec le token)."""
    params = {"projectKey": project_key}
    if branch:
        params["branch"] = branch
    url = f"{host.rstrip('/')}/api/qualitygates/project_status?{urllib.parse.urlencode(params)}"
    # Sonar veut une authentification "Basic" avec le token comme identifiant et
    # un mot de passe vide. On encode ça en base64 comme demandé.
    credentials = base64.b64encode(f"{token}:".encode()).decode()
    request = urllib.request.Request(url)
    request.add_header("Authorization", f"Basic {credentials}")
    return request


def fetch_status(request: urllib.request.Request) -> dict:
    """Lance l'appel et renvoie la réponse en JSON (ou lève une erreur réseau)."""
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode())


def main(argv: list[str]) -> int:
    global _CONTEXT

    args = parse_args(argv)
    _CONTEXT = args.project_key

    token = os.environ.get("SONAR_TOKEN", "").strip()
    if not token:
        log("ERREUR : variable d'environnement SONAR_TOKEN manquante ou vide.")
        return 1

    request = build_request(args.host, args.project_key, args.branch, token)
    deadline = time.monotonic() + args.timeout

    while True:
        try:
            payload = fetch_status(request)
        except urllib.error.HTTPError as exc:
            # Une erreur 404 veut souvent dire que l'analyse n'est pas encore
            # arrivée sur Sonar. Tant qu'on a le temps, on réessaie.
            if exc.code == 404 and time.monotonic() < deadline:
                log("Analyse pas encore disponible (404), nouvelle tentative...")
                time.sleep(args.poll)
                continue
            log(f"ERREUR HTTP {exc.code} lors de l'appel à SonarCloud : {describe_http_error(exc)}")
            if exc.code in (401, 403):
                # Deux causes possibles, le message de Sonar ci-dessus les départage :
                #  - "non main branches" : limite du plan gratuit, l'API ne sert le
                #    Quality Gate que pour la branche principale du projet ;
                #  - "Insufficient privileges" : SONAR_TOKEN est un token d'analyse
                #    (Project/Global Analysis Token), qui pousse une analyse mais ne
                #    peut pas la relire. Il faut un token personnel avec « Browse ».
                log("  → voir le message de Sonar ci-dessus : soit la branche n'est pas")
                log("    la branche principale (non couvert par le plan gratuit), soit")
                log("    SONAR_TOKEN n'a pas la permission « Browse » sur ce projet.")
            return 1
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            log(f"ERREUR technique lors de l'appel à SonarCloud : {exc}")
            return 1

        status = payload.get("projectStatus", {}).get("status")

        if status in (None, "NONE"):
            if time.monotonic() >= deadline:
                log("ERREUR : délai dépassé, aucun résultat de Quality Gate.")
                return 1
            log("Résultat pas encore prêt, attente...")
            time.sleep(args.poll)
            continue

        if status == "OK":
            log("Quality Gate : OK ✔")
            return 0

        # Ici le Quality Gate est en échec : on affiche les règles qui n'ont pas
        # été respectées pour comprendre ce qui coince.
        log(f"Quality Gate : ÉCHEC ({status})")
        for condition in payload.get("projectStatus", {}).get("conditions", []):
            if condition.get("status") == "ERROR":
                log(
                    "  - {metric} : {actual} (seuil {op} {threshold})".format(
                        metric=condition.get("metricKey", "?"),
                        actual=condition.get("actualValue", "?"),
                        op=condition.get("comparator", "?"),
                        threshold=condition.get("errorThreshold", "?"),
                    )
                )
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
