#!/usr/bin/env python3
"""collect_dora.py

Ce script calcule les quatre indicateurs DORA du projet à partir de l'historique
des pipelines GitLab, et les sort en JSON (pour un tableau de bord Kibana, ou
juste pour être lu). Les quatre indicateurs sont : la fréquence de déploiement,
le délai de mise en production (lead time), le temps de rétablissement (MTTR) et
le taux d'échec des changements.

La règle qui gouverne tout le script :
    un indicateur qu'on ne peut pas mesurer vaut `null`, accompagné de la raison,
    jamais `0`. La confusion entre « aucune donnée » et « zéro » est le pire
    défaut d'un tableau de bord : un `0` se lit comme une performance. Aujourd'hui
    le projet n'a AUCUN déploiement réussi, donc le lead time et le MTTR n'ont
    pas de valeur — pas une valeur nulle, pas de valeur du tout.

Comment ça marche :
    Le script lit la liste des pipelines du projet, puis les jobs de chacun. Il
    repère les déploiements et les retours arrière par leur NOM de job (l'API des
    « deployments » de GitLab, elle, demande un jeton même sur un projet public).
    Ensuite il calcule :
      - fréquence      = déploiements réussis / durée de la fenêtre ;
      - lead time      = médiane de (fin du déploiement réussi - date du commit) ;
      - MTTR           = médiane de (fin du déploiement réussi - fin du premier
                         échec de la série qu'il répare) ;
      - taux d'échec   = tentatives ratées / tentatives, en %.
    Une tentative, c'est un job de déploiement RÉELLEMENT exécuté : les jobs
    `manual` jamais déclenchés et les `skipped` n'en sont pas, les compter
    inventerait des déploiements qui n'ont pas eu lieu. Un déploiement réussi
    suivi d'un rollback compte comme un échec : c'est la définition DORA du taux
    d'échec des changements (un changement qui a dégradé la production).
    Comme les autres scripts du dépôt, celui-ci n'utilise que la bibliothèque
    standard : le job CI tourne dans python:3.12-slim, sans pip ni requests.

Les options :
    --project ID          Projet GitLab (id numérique ou chemin). Défaut : 84606666
    --host URL            Instance GitLab. Défaut : https://gitlab.com
    --token TOKEN         Jeton GitLab (sinon $GITLAB_TOKEN). Facultatif, voir plus bas.
    --days N              Fenêtre glissante en jours. Défaut : 30. `0` = tout l'historique.
    --deploy-jobs A,B     Noms des jobs de déploiement.
                          Défaut : deploy-staging,deploy-production
    --rollback-jobs A,B   Noms des jobs de retour arrière. Défaut : rollback-production
    --output FICHIER      Écrit le JSON dans ce fichier au lieu de la sortie standard.
    --elasticsearch URL   Envoie aussi les documents en `_bulk` vers cet Elasticsearch.
    --es-index NOM        Index de destination. Défaut : microcrm-dora
    --fixtures RÉPERTOIRE Lit les réponses d'API dans des fichiers au lieu du réseau.

À propos du jeton :
    Il est FACULTATIF ici parce que le projet est public : la liste des pipelines
    et les jobs d'un pipeline se lisent sans authentification. Le jeton sert à
    lire les projets privés, l'API `/deployments` et l'API globale `/jobs` (toutes
    deux en 401 sans jeton) — le script ne s'en sert pas, justement pour rester
    utilisable sans secret. Quand il est fourni, il part dans l'en-tête
    PRIVATE-TOKEN et n'est jamais affiché ni recopié dans le JSON.

Le mode --fixtures :
    C'est ce qui rend le script testable sans jeton et sans réseau. Le répertoire
    doit contenir :
      - `gitlab-pipelines.json`               : la réponse de /pipelines ;
      - `gitlab-pipeline-jobs*.json`          : des réponses de /pipelines/:id/jobs.
    Les jobs sont rattachés à leur pipeline par le champ `pipeline.id` qu'ils
    portent déjà, sinon par l'id lu dans le nom du fichier. Un pipeline sans
    fichier de jobs est compté dans `perimetre.pipelines_sans_jobs` : un jeu de
    fixtures partiel doit se voir, pas se faire passer pour l'histoire complète.
    Les fixtures du dépôt sont de vrais enregistrements de l'API, sauf le
    répertoire `dora-scenario-fabrique/` qui est FABRIQUÉ : il existe pour
    éprouver le cas « des déploiements ont réussi », que la réalité du projet
    n'offre pas encore.

Ce que renvoie le script :
    0 = collecte terminée (même si des indicateurs sont `null`, c'est un résultat)
    1 = erreur technique (réseau, fixtures illisibles, envoi Elasticsearch raté)

Exemples :
    scripts/ci/collect_dora.py --project 84606666 --days 30
    scripts/ci/collect_dora.py --fixtures scripts/tests/fixtures --days 0
    scripts/ci/collect_dora.py --elasticsearch http://elasticsearch:9200
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

DEFAULT_PROJECT = "84606666"
DEFAULT_HOST = "https://gitlab.com"
DEFAULT_DEPLOY_JOBS = "deploy-staging,deploy-production"
DEFAULT_ROLLBACK_JOBS = "rollback-production"
DEFAULT_ES_INDEX = "microcrm-dora"

# Un job de déploiement ne « compte » que s'il a vraiment tourné. `manual` (créé
# mais jamais déclenché), `skipped`, `created`... décrivent des déploiements qui
# n'ont pas eu lieu. `canceled` est volontairement exclu aussi : on ne sait pas
# si la production a été touchée avant l'annulation, et deviner fausserait le
# taux d'échec dans un sens comme dans l'autre.
STATUTS_EXECUTES = {"success", "failed"}

PAGE_SIZE = 100


def log(message: str) -> None:
    print(f"[collect_dora] {message}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Sources de données : l'API réelle, ou des fichiers. Le calcul ne sait pas
# laquelle des deux il interroge, c'est ce qui permet de tester hors réseau.
# --------------------------------------------------------------------------


class SourceGitLab:
    """Lit l'API GitLab, avec pagination."""

    def __init__(self, host: str, project: str, token: str | None) -> None:
        # Un chemin de projet ("groupe/projet") doit être encodé, un id numérique
        # passe tel quel ; urlencode des deux côtés ne coûte rien.
        self.base = f"{host.rstrip('/')}/api/v4/projects/{urllib.parse.quote(str(project), safe='')}"
        self.token = token
        self.libelle = f"API {host.rstrip('/')} (projet {project})"

    def _get(self, chemin: str, params: dict) -> tuple[list, dict]:
        url = f"{self.base}{chemin}?{urllib.parse.urlencode(params)}"
        requete = urllib.request.Request(url)
        if self.token:
            requete.add_header("PRIVATE-TOKEN", self.token)
        with urllib.request.urlopen(requete, timeout=30) as reponse:
            return json.loads(reponse.read().decode()), dict(reponse.headers)

    def _paginer(self, chemin: str, params: dict) -> list:
        """Parcourt toutes les pages.

        GitLab ne renvoie pas toujours X-Total (les projets récents utilisent une
        pagination « keyset » sans total), donc on suit X-Next-Page et, à défaut,
        on s'arrête sur une page incomplète.
        """
        resultats: list = []
        page = 1
        while True:
            lot, entetes = self._get(chemin, {**params, "per_page": PAGE_SIZE, "page": page})
            resultats.extend(lot)
            suivante = entetes.get("X-Next-Page", "").strip()
            if suivante:
                page = int(suivante)
                continue
            if len(lot) < PAGE_SIZE:
                return resultats
            page += 1

    def pipelines(self, depuis: datetime | None) -> list:
        params = {"order_by": "id", "sort": "desc"}
        if depuis:
            # Filtrer côté serveur évite de télécharger des années d'historique
            # pour une fenêtre de 30 jours.
            params["updated_after"] = iso(depuis)
        return self._paginer("/pipelines", params)

    def jobs(self, pipeline_id: int) -> list | None:
        # include_retried : sans ça, un déploiement rejoué masque sa propre
        # tentative ratée, et le taux d'échec s'améliore tout seul.
        return self._paginer(f"/pipelines/{pipeline_id}/jobs", {"include_retried": "true"})


class SourceFixtures:
    """Rejoue des réponses d'API enregistrées dans des fichiers."""

    def __init__(self, repertoire: str) -> None:
        self.repertoire = repertoire
        self.libelle = f"fixtures {repertoire}"
        self._pipelines = self._lire(os.path.join(repertoire, "gitlab-pipelines.json"))
        self._jobs_par_pipeline: dict[int, list] = {}
        for chemin in sorted(glob.glob(os.path.join(repertoire, "gitlab-pipeline-jobs*.json"))):
            # L'id du pipeline est porté par les jobs eux-mêmes ; le nom de
            # fichier ne sert que de secours pour un enregistrement allégé.
            secours = re.search(r"jobs-(\d+)\.json$", os.path.basename(chemin))
            for job in self._lire(chemin):
                pid = (job.get("pipeline") or {}).get("id")
                if pid is None and secours:
                    pid = int(secours.group(1))
                if pid is not None:
                    self._jobs_par_pipeline.setdefault(int(pid), []).append(job)

    @staticmethod
    def _lire(chemin: str) -> list:
        with open(chemin, encoding="utf-8") as fichier:
            contenu = json.load(fichier)
        if not isinstance(contenu, list):
            raise ValueError(f"{chemin} : une liste JSON était attendue.")
        return contenu

    def pipelines(self, depuis: datetime | None) -> list:
        # Le filtrage par date est fait plus loin sur les événements ; ici on
        # rend tout, une fixture n'a pas de coût de transfert.
        return list(self._pipelines)

    def jobs(self, pipeline_id: int) -> list | None:
        # `None` (et non `[]`) distingue « ce pipeline n'a pas été enregistré »
        # de « ce pipeline n'avait aucun job ».
        return self._jobs_par_pipeline.get(int(pipeline_id))


# --------------------------------------------------------------------------
# Dates
# --------------------------------------------------------------------------


def parse_date(valeur: str | None) -> datetime | None:
    """Convertit une date GitLab en datetime UTC, ou None si elle est absente."""
    if not valeur:
        return None
    try:
        # GitLab mélange les suffixes ("...Z" pour les jobs, "+02:00" pour les
        # commits) ; on ramène tout en UTC pour que les soustractions aient un sens.
        return datetime.fromisoformat(valeur.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def mediane(valeurs: list[float]) -> float:
    ordonnees = sorted(valeurs)
    milieu = len(ordonnees) // 2
    if len(ordonnees) % 2:
        return ordonnees[milieu]
    return (ordonnees[milieu - 1] + ordonnees[milieu]) / 2


# --------------------------------------------------------------------------
# Extraction des événements
# --------------------------------------------------------------------------


def evenement(job: dict, pipeline: dict, categorie: str) -> dict:
    """Réduit un job GitLab à ce dont le calcul a besoin.

    Les réponses de l'API pèsent des kilo-octets par job (utilisateur, commit,
    artefacts...) ; tout garder rendrait le JSON de sortie illisible et
    exposerait des données inutiles dans Elasticsearch.
    """
    commit = job.get("commit") or {}
    fin = parse_date(job.get("finished_at")) or parse_date(job.get("created_at"))
    return {
        "categorie": categorie,
        "job_id": job.get("id"),
        "job": job.get("name"),
        "statut": job.get("status"),
        "pipeline_id": pipeline.get("id"),
        "ref": job.get("ref") or pipeline.get("ref"),
        "sha": (commit.get("id") or pipeline.get("sha") or "")[:8],
        "fin": iso(fin) if fin else None,
        "_fin": fin,
        "_commit": parse_date(commit.get("committed_date") or commit.get("created_at")),
        "raison_echec": job.get("failure_reason"),
    }


def collecter_evenements(source, deploy_jobs: set, rollback_jobs: set,
                         depuis: datetime | None) -> tuple[list, dict]:
    """Parcourt les pipelines et en extrait les déploiements et rollbacks exécutés."""
    pipelines = source.pipelines(depuis)
    evenements: list[dict] = []
    sans_jobs = 0
    ignores = 0

    for pipeline in pipelines:
        jobs = source.jobs(pipeline["id"])
        if jobs is None:
            sans_jobs += 1
            continue
        for job in jobs:
            nom = job.get("name")
            if nom in deploy_jobs:
                categorie = "deploiement"
            elif nom in rollback_jobs:
                categorie = "rollback"
            else:
                continue
            if job.get("status") not in STATUTS_EXECUTES:
                ignores += 1
                continue
            evenements.append(evenement(job, pipeline, categorie))

    # L'ordre chronologique est une précondition du MTTR et du rattachement des
    # rollbacks : sans lui, « l'échec suivant » n'a pas de sens.
    evenements.sort(key=lambda e: e["_fin"] or datetime.min.replace(tzinfo=timezone.utc))

    dates = [parse_date(p.get("created_at")) for p in pipelines]
    dates = [d for d in dates if d]
    perimetre = {
        "pipelines_analyses": len(pipelines),
        "pipelines_sans_jobs": sans_jobs,
        "premier_pipeline": iso(min(dates)) if dates else None,
        "dernier_pipeline": iso(max(dates)) if dates else None,
        "jobs_deploiement_executes": sum(1 for e in evenements if e["categorie"] == "deploiement"),
        "jobs_deploiement_non_executes": ignores,
        "jobs_rollback_executes": sum(1 for e in evenements if e["categorie"] == "rollback"),
    }
    return evenements, perimetre


# --------------------------------------------------------------------------
# Les quatre indicateurs
# --------------------------------------------------------------------------


def indicateur(cle: str, libelle: str, unite: str, observations: int,
               valeur=None, raison: str | None = None, commentaire: str = "",
               details: dict | None = None) -> dict:
    """Construit un indicateur. `valeur=None` EXIGE une raison lisible."""
    if valeur is None and not raison:
        raise ValueError(f"indicateur {cle} sans valeur ni raison")
    resultat = {
        "cle": cle,
        "libelle": libelle,
        "valeur": valeur,
        "unite": unite,
        "observations": observations,
        "raison": raison if valeur is None else None,
        "commentaire": commentaire,
    }
    if details:
        resultat["details"] = details
    return resultat


def frequence_deploiement(reussis: list, jours_fenetre: float, tentatives: int) -> dict:
    # Ici, 0 est bien une mesure et non une absence de donnée : on a observé la
    # fenêtre entière, et rien n'y a été déployé. Le commentaire est là pour que
    # personne ne lise ce 0 comme « pas encore calculé ».
    valeur = round(len(reussis) / jours_fenetre, 4) if jours_fenetre > 0 else 0.0
    if reussis:
        commentaire = (f"{len(reussis)} déploiement(s) réussi(s) sur "
                       f"{jours_fenetre:.1f} jours observés.")
    else:
        commentaire = (f"Aucun déploiement réussi sur {jours_fenetre:.1f} jours observés "
                       f"({tentatives} tentative(s) exécutée(s)). La valeur 0 est mesurée, "
                       f"pas manquante.")
    return indicateur("deployment_frequency", "Fréquence de déploiement",
                      "déploiements par jour", len(reussis), valeur=valeur,
                      commentaire=commentaire)


def lead_time(reussis: list) -> dict:
    # Mesuré du commit qui a déclenché le pipeline jusqu'à la fin du déploiement.
    # C'est le commit de tête du pipeline : l'API des jobs n'expose pas les
    # commits intermédiaires, la mesure est donc un minorant assumé.
    durees = [(e["_fin"] - e["_commit"]).total_seconds() / 3600.0
              for e in reussis if e["_fin"] and e["_commit"]]
    if not durees:
        raison = ("Aucun déploiement réussi sur la fenêtre : il n'existe aucune arrivée "
                  "en production vers laquelle mesurer un délai.")
        return indicateur("lead_time_for_changes", "Délai de mise en production (médiane)",
                          "heures", 0, valeur=None, raison=raison,
                          commentaire="Indicateur non mesurable, à ne pas lire comme 0.")
    return indicateur("lead_time_for_changes", "Délai de mise en production (médiane)",
                      "heures", len(durees), valeur=round(mediane(durees), 2),
                      commentaire=f"Médiane sur {len(durees)} déploiement(s) réussi(s), "
                                  f"du commit de tête à la fin du déploiement.",
                      details={"min": round(min(durees), 2), "max": round(max(durees), 2)})


def mttr(evenements: list) -> dict:
    """Temps de rétablissement : d'un échec de déploiement au succès SUIVANT."""
    durees = []
    debut_panne = None
    pannes_ouvertes = 0
    for e in (x for x in evenements if x["categorie"] == "deploiement"):
        if e["statut"] == "failed":
            # Seul le PREMIER échec d'une série compte : la panne dure depuis lui,
            # les échecs suivants sont des tentatives de réparation ratées.
            if debut_panne is None:
                debut_panne = e["_fin"]
        elif e["statut"] == "success" and debut_panne is not None:
            durees.append((e["_fin"] - debut_panne).total_seconds() / 3600.0)
            debut_panne = None
    if debut_panne is not None:
        pannes_ouvertes = 1

    if not durees:
        raison = ("Aucune panne de déploiement n'a été rétablie : le MTTR se mesure d'un "
                  "échec jusqu'au succès suivant, et ce succès n'existe pas.")
        if pannes_ouvertes:
            raison += " Une panne est encore ouverte à la fin de la fenêtre."
        return indicateur("mean_time_to_restore", "Temps de rétablissement (médiane)",
                          "heures", 0, valeur=None, raison=raison,
                          commentaire="Indicateur non mesurable, à ne pas lire comme 0.")
    commentaire = f"Médiane sur {len(durees)} rétablissement(s) observé(s)."
    if pannes_ouvertes:
        commentaire += " Une panne encore ouverte n'est pas comptée."
    return indicateur("mean_time_to_restore", "Temps de rétablissement (médiane)",
                      "heures", len(durees), valeur=round(mediane(durees), 2),
                      commentaire=commentaire,
                      details={"min": round(min(durees), 2), "max": round(max(durees), 2),
                               "panne_en_cours": bool(pannes_ouvertes)})


def taux_echec(evenements: list) -> dict:
    """Part des déploiements qui ont échoué ou qu'il a fallu annuler."""
    deploiements = [e for e in evenements if e["categorie"] == "deploiement"]
    rollbacks = [e for e in evenements if e["categorie"] == "rollback"]
    if not deploiements:
        raison = ("Aucun job de déploiement n'a été exécuté sur la fenêtre "
                  "(les jobs manuels non déclenchés ne sont pas des tentatives).")
        return indicateur("change_failure_rate", "Taux d'échec des changements",
                          "%", 0, valeur=None, raison=raison,
                          commentaire="Indicateur non mesurable, à ne pas lire comme 0 %.")

    echecs = sum(1 for e in deploiements if e["statut"] == "failed")
    # Un déploiement réussi puis annulé est un changement qui a dégradé la
    # production : la définition DORA le compte comme un échec.
    annules = 0
    for index, e in enumerate(deploiements):
        if e["statut"] != "success":
            continue
        fin_suivant = next((d["_fin"] for d in deploiements[index + 1:]), None)
        for r in rollbacks:
            if r["_fin"] and e["_fin"] and r["_fin"] >= e["_fin"] and (
                    fin_suivant is None or r["_fin"] < fin_suivant):
                annules += 1
                break

    total = len(deploiements)
    valeur = round((echecs + annules) / total * 100.0, 2)
    commentaire = (f"{echecs + annules} échec(s) sur {total} tentative(s) exécutée(s)"
                   f"{f', dont {annules} annulé(s) par rollback' if annules else ''}.")
    return indicateur("change_failure_rate", "Taux d'échec des changements", "%", total,
                      valeur=valeur, commentaire=commentaire,
                      details={"tentatives": total, "echecs_directs": echecs,
                               "reussites_annulees": annules})


def construire_rapport(source, evenements: list, perimetre: dict, jours: int,
                       maintenant: datetime, projet: str) -> dict:
    debut = maintenant - timedelta(days=jours) if jours > 0 else None
    if debut:
        evenements = [e for e in evenements if e["_fin"] and e["_fin"] >= debut]
        jours_fenetre = float(jours)
    else:
        # Sans fenêtre, la fréquence se rapporte à la durée réellement observée ;
        # diviser par une durée arbitraire donnerait un chiffre faux.
        dates = [e["_fin"] for e in evenements if e["_fin"]]
        bornes = [parse_date(perimetre.get("premier_pipeline")),
                  parse_date(perimetre.get("dernier_pipeline"))]
        bornes = [b for b in bornes if b] or dates
        jours_fenetre = max(((max(bornes) - min(bornes)).total_seconds() / 86400.0) if bornes else 0.0, 1.0)

    deploiements = [e for e in evenements if e["categorie"] == "deploiement"]
    reussis = [e for e in deploiements if e["statut"] == "success"]

    indicateurs = [
        frequence_deploiement(reussis, jours_fenetre, len(deploiements)),
        lead_time(reussis),
        mttr(evenements),
        taux_echec(evenements),
    ]

    return {
        "genere_le": iso(maintenant),
        "projet": str(projet),
        "source": source.libelle,
        "fenetre": {
            "jours": jours if jours > 0 else None,
            "debut": iso(debut) if debut else None,
            "fin": iso(maintenant),
            "jours_observes": round(jours_fenetre, 2),
        },
        "perimetre": perimetre,
        "indicateurs": indicateurs,
        # Les événements retenus rendent chaque chiffre vérifiable à la main :
        # sans eux, un indicateur `null` ressemble à un bug du script.
        "evenements": [{k: v for k, v in e.items() if not k.startswith("_")} for e in evenements],
    }


# --------------------------------------------------------------------------
# Elasticsearch
# --------------------------------------------------------------------------


def documents_bulk(rapport: dict, index: str) -> str:
    """Prépare le corps NDJSON de l'API _bulk.

    Chaque document porte un `_id` déterministe : relancer la collecte met à jour
    le document existant au lieu d'empiler des doublons qui fausseraient les
    graphiques Kibana.
    """
    horodatage = rapport["genere_le"]
    jour = horodatage[:10]
    lignes = []
    for ind in rapport["indicateurs"]:
        doc = {"@timestamp": horodatage, "type": "indicateur", "projet": rapport["projet"],
               "fenetre_jours": rapport["fenetre"]["jours"], **ind}
        lignes.append(json.dumps({"index": {"_index": index, "_id": f"{jour}-{ind['cle']}"}}))
        lignes.append(json.dumps(doc, ensure_ascii=False))
    for evt in rapport["evenements"]:
        doc = {"@timestamp": evt["fin"], "type": "evenement", "projet": rapport["projet"], **evt}
        lignes.append(json.dumps({"index": {"_index": index, "_id": f"job-{evt['job_id']}"}}))
        lignes.append(json.dumps(doc, ensure_ascii=False))
    return "\n".join(lignes) + "\n"


def envoyer_elasticsearch(url: str, index: str, rapport: dict) -> bool:
    corps = documents_bulk(rapport, index).encode("utf-8")
    requete = urllib.request.Request(f"{url.rstrip('/')}/_bulk", data=corps, method="POST")
    requete.add_header("Content-Type", "application/x-ndjson")
    try:
        with urllib.request.urlopen(requete, timeout=30) as reponse:
            reponse_json = json.loads(reponse.read().decode())
    except urllib.error.HTTPError as exc:
        log(f"ERREUR : Elasticsearch a répondu {exc.code} ({exc.reason}).")
        return False
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        log(f"ERREUR : envoi Elasticsearch impossible : {exc}")
        return False

    # _bulk répond 200 même quand des documents ont été rejetés : le seul moyen
    # de savoir si l'indexation a marché est de relire le drapeau "errors".
    if reponse_json.get("errors"):
        refus = [item for action in reponse_json.get("items", [])
                 for item in action.values() if item.get("error")]
        log(f"ERREUR : {len(refus)} document(s) refusé(s) par Elasticsearch.")
        if refus:
            log(f"  → premier refus : {refus[0].get('error')}")
        return False
    log(f"{len(reponse_json.get('items', []))} document(s) indexé(s) dans « {index} ».")
    return True


# --------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Calcule les quatre indicateurs DORA depuis l'historique des pipelines GitLab.",
        epilog="Un indicateur non mesurable sort en `null` avec sa raison, jamais en 0.")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="Id ou chemin du projet GitLab.")
    parser.add_argument("--host", default=DEFAULT_HOST, help="Instance GitLab.")
    parser.add_argument("--token", default=None,
                        help="Jeton GitLab (défaut : $GITLAB_TOKEN). Facultatif si le projet est public.")
    parser.add_argument("--days", type=int, default=30,
                        help="Fenêtre glissante en jours (0 = tout l'historique).")
    parser.add_argument("--deploy-jobs", default=DEFAULT_DEPLOY_JOBS,
                        help="Noms des jobs de déploiement, séparés par des virgules.")
    parser.add_argument("--rollback-jobs", default=DEFAULT_ROLLBACK_JOBS,
                        help="Noms des jobs de retour arrière, séparés par des virgules.")
    parser.add_argument("--output", default=None, help="Fichier de sortie (défaut : stdout).")
    parser.add_argument("--elasticsearch", default=None, help="URL d'un Elasticsearch (API _bulk).")
    parser.add_argument("--es-index", default=DEFAULT_ES_INDEX, help="Index Elasticsearch.")
    parser.add_argument("--fixtures", default=None,
                        help="Répertoire de fixtures à rejouer au lieu d'appeler l'API.")
    return parser.parse_args(argv)


def noms(valeur: str) -> set:
    return {nom.strip() for nom in valeur.split(",") if nom.strip()}


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.days < 0:
        log("ERREUR : --days doit être positif (0 = tout l'historique).")
        return 1

    if args.fixtures:
        try:
            source = SourceFixtures(args.fixtures)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            log(f"ERREUR : fixtures illisibles : {exc}")
            return 1
    else:
        # Le jeton n'est jamais journalisé, seulement sa présence.
        token = args.token or os.environ.get("GITLAB_TOKEN", "").strip() or None
        log(f"Jeton GitLab : {'fourni' if token else 'absent (lecture publique)'}.")
        source = SourceGitLab(args.host, args.project, token)

    maintenant = datetime.now(timezone.utc)
    depuis = maintenant - timedelta(days=args.days) if args.days > 0 else None

    try:
        evenements, perimetre = collecter_evenements(
            source, noms(args.deploy_jobs), noms(args.rollback_jobs), depuis)
    except urllib.error.HTTPError as exc:
        log(f"ERREUR HTTP {exc.code} ({exc.reason}) en interrogeant GitLab.")
        if exc.code in (401, 403):
            log("  → projet privé ou jeton invalide : fournir --token / $GITLAB_TOKEN.")
        return 1
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        log(f"ERREUR technique en interrogeant {source.libelle} : {exc}")
        return 1

    rapport = construire_rapport(source, evenements, perimetre, args.days, maintenant, args.project)

    for ind in rapport["indicateurs"]:
        etat = "non mesurable" if ind["valeur"] is None else f"{ind['valeur']} {ind['unite']}"
        log(f"{ind['libelle']} : {etat}")

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
