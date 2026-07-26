#!/usr/bin/env python3
"""check_coverage.py

Ce script vérifie que la couverture de tests du back ne passe pas en dessous
d'un certain pourcentage. C'est un petit garde-fou en plus de Sonar : il est
rapide et il marche même sans connexion (il lit juste le fichier de JaCoCo).

Comment ça marche :
    JaCoCo génère un fichier XML (`jacocoTestReport.xml`) avec les chiffres de
    couverture. Le script lit ce fichier, récupère le pourcentage de lignes
    couvertes (LINE par défaut) et le compare au seuil qu'on lui donne :
        - il renvoie 0 si la couverture est suffisante,
        - il renvoie 2 si elle est trop basse,
        - il renvoie 1 s'il y a une erreur (fichier absent, XML cassé...).
    Comme pour l'autre script, j'utilise seulement des modules de base de Python.

Les options :
    --report PATH    Le chemin du fichier XML de JaCoCo (obligatoire).
    --min PERCENT    Le pourcentage minimum voulu. Par défaut : 80
    --counter TYPE   Ce qu'on mesure : LINE, INSTRUCTION, BRANCH, METHOD, CLASS
                     ou COMPLEXITY. Par défaut : LINE

Ce que renvoie le script :
    0 = seuil respecté · 1 = erreur technique · 2 = couverture trop basse

Exemple :
    scripts/ci/check_coverage.py \
        --report back/build/reports/jacoco/test/jacocoTestReport.xml --min 70
"""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET

VALID_COUNTERS = {"LINE", "INSTRUCTION", "BRANCH", "METHOD", "CLASS", "COMPLEXITY"}


def log(message: str) -> None:
    print(f"[check_coverage] {message}", file=sys.stderr, flush=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vérifie un seuil de couverture JaCoCo.")
    parser.add_argument("--report", required=True, help="Chemin du rapport JaCoCo XML.")
    parser.add_argument("--min", type=float, default=80.0, help="Seuil minimal (%%).")
    parser.add_argument("--counter", default="LINE", choices=sorted(VALID_COUNTERS),
                        help="Type de compteur JaCoCo.")
    return parser.parse_args(argv)


def read_coverage(report_path: str, counter_type: str) -> float:
    """Renvoie le pourcentage couvert. Lève une erreur si le compteur n'existe pas."""
    # Dans le fichier JaCoCo, les totaux sont dans des balises <counter> juste
    # sous la balise <report>. On cherche celle qui correspond à ce qu'on veut.
    tree = ET.parse(report_path)
    root = tree.getroot()
    for counter in root.findall("counter"):
        if counter.get("type") != counter_type:
            continue
        missed = int(counter.get("missed", "0"))
        covered = int(counter.get("covered", "0"))
        total = missed + covered
        if total == 0:
            raise ValueError(f"Compteur '{counter_type}' vide (aucun élément mesuré).")
        return covered / total * 100.0
    raise ValueError(f"Compteur '{counter_type}' introuvable dans le rapport.")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        coverage = read_coverage(args.report, args.counter)
    except FileNotFoundError:
        log(f"ERREUR : rapport introuvable : {args.report}")
        return 1
    except ET.ParseError as exc:
        log(f"ERREUR : rapport XML invalide : {exc}")
        return 1
    except ValueError as exc:
        log(f"ERREUR : {exc}")
        return 1

    log(f"Couverture {args.counter} : {coverage:.2f}% (seuil : {args.min:.2f}%)")
    if coverage + 1e-9 < args.min:
        log("Couverture insuffisante -> échec.")
        return 2
    log("Seuil de couverture respecté ✔")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
