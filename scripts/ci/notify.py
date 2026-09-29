#!/usr/bin/env python3
"""notify.py

Ce script annonce le résultat d'une étape du pipeline sur un canal d'équipe
(Slack, Mattermost, Discord — tout ce qui accepte un webhook JSON).

Le manque qu'il comble : jusqu'ici, un déploiement raté ne se voyait qu'en
ouvrant GitLab. Personne n'était prévenu, donc personne ne regardait, donc un
échec pouvait rester ignoré jusqu'à ce que quelqu'un s'en aperçoive par hasard.

Comment ça marche :
    L'adresse du webhook vient de la variable d'environnement
    NOTIFY_WEBHOOK_URL, jamais du dépôt : c'est un secret, il vit dans les
    variables CI/CD du projet. Le message est composé à partir des variables
    que GitLab pose dans chaque job (projet, branche, commit, lien du job).

Trois partis pris, et chacun a sa raison :

    1. **Webhook absent = rien à faire, et surtout PAS un échec.** Le script
       sort en 0 avec une trace. Sans cela, un dépôt cloné sans la variable
       verrait tous ses pipelines rougir sur une notification non configurée —
       et on apprendrait à ignorer les jobs rouges, ce qui est bien pire que
       l'absence de notification.

    2. **Une notification qui échoue ne fait jamais échouer le pipeline.** Un
       canal indisponible ne dit rien sur la qualité du déploiement. Faire
       rougir un déploiement réussi parce que Slack est en panne serait une
       fausse alerte, et les fausses alertes coûtent la confiance qu'on essaie
       justement de construire. L'erreur est journalisée, le code reste 0.

    3. **Pas de dépendance externe.** Même règle que le reste de scripts/ci/ :
       le job tourne dans une image qui n'a pas `pip install`. urllib suffit.

Les options :
    --statut STATUT  Résultat à annoncer : success, failed, canceled...
                     En CI, passer "$CI_JOB_STATUS" (posé par GitLab dans
                     after_script). Obligatoire.
    --sujet TEXTE    Ce dont on parle, en clair. Ex : "Déploiement production".
                     Obligatoire.
    --detail TEXTE   Une précision facultative ajoutée au message.
    --dry-run        Compose le message et l'affiche, sans rien envoyer.
                     C'est le mode qu'utilisent les tests.

Variables d'environnement lues :
    NOTIFY_WEBHOOK_URL  L'adresse du webhook. Absente = rien n'est envoyé.
    CI_PROJECT_PATH, CI_COMMIT_REF_NAME, CI_COMMIT_SHORT_SHA,
    CI_JOB_NAME, CI_JOB_URL, CI_PIPELINE_URL  — posées par GitLab.

Ce que renvoie le script :
    0 = message envoyé, ou rien à envoyer, ou envoi échoué (voir parti pris 2)
    2 = erreur d'utilisation (option manquante, renvoyée par argparse)

Exemple :
    scripts/ci/notify.py --statut "$CI_JOB_STATUS" --sujet "Déploiement production"
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

TIMEOUT_S = 10

# Un pictogramme par statut. Le texte reste lisible sans, mais dans un canal
# qui défile, c'est ce qui permet de repérer un échec sans lire la ligne.
PICTOGRAMMES = {
    "success": "✅",
    "failed": "❌",
    "canceled": "⚪",
}


def log(message: str) -> None:
    print(f"[notify] {message}", file=sys.stderr, flush=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    # L'épilogue nomme la variable d'environnement : c'est la première question
    # de qui lance ce script sans rien avoir configuré, et argparse n'affiche
    # pas la docstring du module.
    parser = argparse.ArgumentParser(
        description="Annonce le résultat d'une étape du pipeline sur un webhook.",
        epilog=(
            "Variable d'environnement : NOTIFY_WEBHOOK_URL — l'adresse du webhook. "
            "Absente, rien n'est envoyé et le script sort en 0 (le message reste "
            "écrit dans le journal du job)."),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--statut", required=True,
                        help="Résultat à annoncer (success, failed, canceled...).")
    parser.add_argument("--sujet", required=True,
                        help="Ce dont on parle, en clair.")
    parser.add_argument("--detail", default="",
                        help="Précision facultative ajoutée au message.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Affiche le message sans l'envoyer.")
    return parser.parse_args(argv)


def compose_message(statut: str, sujet: str, detail: str,
                    env: dict[str, str]) -> str:
    """Compose le texte du message à partir du statut et du contexte GitLab.

    Les variables CI sont lues avec un défaut vide : le script doit rester
    exécutable en local, où aucune d'elles n'existe. Une ligne de contexte
    absente vaut mieux qu'un plantage sur une clé manquante.
    """
    picto = PICTOGRAMMES.get(statut.lower(), "•")
    lignes = [f"{picto} {sujet} — {statut}"]

    projet = env.get("CI_PROJECT_PATH", "")
    branche = env.get("CI_COMMIT_REF_NAME", "")
    commit = env.get("CI_COMMIT_SHORT_SHA", "")
    if projet or branche or commit:
        contexte = " · ".join(p for p in (projet, branche, commit) if p)
        lignes.append(contexte)

    if detail:
        lignes.append(detail)

    # Le lien du job d'abord : c'est celui qui porte le journal de l'échec.
    # Celui du pipeline ne sert que s'il n'y a pas de job (peu probable en CI,
    # mais le script tourne aussi à la main).
    lien = env.get("CI_JOB_URL") or env.get("CI_PIPELINE_URL") or ""
    if lien:
        lignes.append(lien)

    return "\n".join(lignes)


def envoyer(url: str, message: str) -> bool:
    """Envoie le message au webhook. Renvoie True si l'envoi a abouti.

    N'attrape pas les erreurs pour les masquer : elles sont journalisées par
    l'appelant, qui décide (et décide de ne pas faire échouer le pipeline).
    """
    charge = json.dumps({"text": message}).encode("utf-8")
    requete = urllib.request.Request(
        url, data=charge,
        headers={"Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(requete, timeout=TIMEOUT_S) as reponse:
        return 200 <= reponse.status < 300


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    message = compose_message(args.statut, args.sujet, args.detail, dict(os.environ))

    if args.dry_run:
        print(message)
        return 0

    url = os.environ.get("NOTIFY_WEBHOOK_URL", "").strip()
    if not url:
        # Parti pris 1 : ce n'est pas une erreur, c'est une absence de
        # configuration. Le message est tout de même écrit dans le journal du
        # job, où il reste consultable.
        log("NOTIFY_WEBHOOK_URL absente : aucune notification envoyée.")
        log(message)
        return 0

    try:
        if envoyer(url, message):
            log(f"Notification envoyée : {args.sujet} — {args.statut}")
        else:
            log("Le webhook a répondu un code inattendu ; notification perdue.")
    except (urllib.error.URLError, OSError, ValueError) as erreur:
        # Parti pris 2 : on ne fait pas rougir un déploiement réussi parce que
        # le canal est injoignable.
        log(f"Envoi impossible ({erreur}) ; le pipeline n'en est pas affecté.")
        log(message)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
