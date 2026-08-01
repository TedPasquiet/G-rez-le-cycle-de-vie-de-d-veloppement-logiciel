/**
 * load.js — charge nominale. C'est ce scénario qui porte les vrais seuils.
 *
 * Un CRM lit beaucoup plus qu'il n'écrit : je fais donc tourner deux
 * populations en parallèle plutôt qu'un parcours moyen unique.
 *   - `lecture`  : montée / palier / descente, avec une pause entre deux clics.
 *   - `ecriture` : rythme fixe et faible, démarré après la montée. Rythme fixe
 *                  = si l'API ralentit, la charge ne baisse pas toute seule et
 *                  le problème se voit.
 *
 *   K6_LOAD_VUS         utilisateurs en lecture  (défaut 10)
 *   K6_LOAD_RAMP        montée et descente       (défaut 20s)
 *   K6_LOAD_DURATION    palier                   (défaut 40s)
 *   K6_LOAD_WRITE_RPS   écritures par seconde    (défaut 2)
 *
 * Lancer : k6 run tests/k6/load.js
 *          K6_LOAD_VUS=25 K6_LOAD_DURATION=2m k6 run tests/k6/load.js
 */

import { envTexte, envNombre, SLO, STATS_RESUME } from './lib/config.js';
import {
  creerPersonne,
  emailUnique,
  lirePersonne,
  listerOrganisations,
  listerOrganisationsDeLaPersonne,
  listerPersonnes,
  nettoyerContexte,
  pauseUtilisateur,
  preparerContexte,
  rechercherParEmail,
  supprimerPersonne,
} from './lib/api.js';

const VUS = envNombre('K6_LOAD_VUS', 10);
const MONTEE = envTexte('K6_LOAD_RAMP', '20s');
const PALIER = envTexte('K6_LOAD_DURATION', '40s');
const ECRITURES_PAR_SECONDE = envNombre('K6_LOAD_WRITE_RPS', 2);

export const options = {
  summaryTrendStats: STATS_RESUME,

  scenarios: {
    lecture: {
      executor: 'ramping-vus',
      exec: 'parcoursLecture',
      startVUs: 0,
      stages: [
        { duration: MONTEE, target: VUS },
        { duration: PALIER, target: VUS },
        { duration: MONTEE, target: 0 },
      ],
      gracefulRampDown: '10s',
    },

    ecriture: {
      executor: 'constant-arrival-rate',
      exec: 'parcoursEcriture',
      startTime: MONTEE, // mesuré pendant le palier, quand le système est au max
      duration: PALIER,
      rate: ECRITURES_PAR_SECONDE,
      timeUnit: '1s',
      // De la réserve pour tenir le rythme même si l'API ralentit, sinon k6
      // signale « insufficient VUs » au lieu de mesurer la lenteur.
      preAllocatedVUs: Math.max(4, ECRITURES_PAR_SECONDE * 3),
      maxVUs: Math.max(10, ECRITURES_PAR_SECONDE * 10),
    },
  },

  // Un seuil par endpoint : c'est ce qui permet de dire « c'est la recherche
  // par email qui décroche » et pas juste « c'est lent ».
  thresholds: {
    http_req_failed: [`rate<${SLO.tauxErreurMax}`],
    checks: [`rate>${1 - SLO.tauxErreurMax}`],

    'http_req_duration{endpoint:list_persons}': [`p(95)<${SLO.p95LectureMs}`],
    'http_req_duration{endpoint:read_person}': [`p(95)<${SLO.p95LectureMs}`],
    'http_req_duration{endpoint:person_orgs}': [`p(95)<${SLO.p95LectureMs}`],
    'http_req_duration{endpoint:list_orgs}': [`p(95)<${SLO.p95LectureMs}`],
    'http_req_duration{endpoint:search_person}': [`p(95)<${SLO.p95LectureMs}`],

    'http_req_duration{endpoint:create_person}': [`p(95)<${SLO.p95EcritureMs}`],
    'http_req_duration{endpoint:delete_person}': [`p(95)<${SLO.p95EcritureMs}`],
  },
};

export function setup() {
  return preparerContexte();
}

// Un utilisateur qui consulte : liste, fiche, organisations liées, recherche.
export function parcoursLecture(contexte) {
  listerPersonnes();
  pauseUtilisateur();

  lirePersonne(contexte.personneId);
  listerOrganisationsDeLaPersonne(contexte.personneId);
  pauseUtilisateur();

  listerOrganisations();
  rechercherParEmail(contexte.email);
  pauseUtilisateur();
}

export function parcoursEcriture() {
  const id = creerPersonne(emailUnique('k6-load'));
  if (id !== null) {
    supprimerPersonne(id);
  }
}

export function teardown(contexte) {
  nettoyerContexte(contexte);
}
