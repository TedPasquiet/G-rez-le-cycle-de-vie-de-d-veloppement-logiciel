/**
 * stress.js — test de stress.
 *
 * On pousse au-delà de la charge nominale, par paliers, pour trouver à partir
 * de combien d'utilisateurs l'API décroche. Ce n'est pas un test qu'on passe
 * ou qu'on rate : c'est une mesure de la marge disponible. Il ne doit donc
 * jamais bloquer le pipeline (job `k6-stress` déclenché à la main).
 *
 * Les seuils ci-dessous ne sont pas un gate mais un repère : les franchir
 * signifie qu'on a dépassé le point de rupture, et le palier atteint à ce
 * moment-là est l'information qu'on cherchait.
 *
 *   K6_STRESS_MAX_VUS     utilisateurs au dernier palier  (défaut 50)
 *   K6_STRESS_STEP        durée d'un palier               (défaut 30s)
 *   K6_P95_STRESS_MS      p95 de rupture                  (défaut 2000)
 *   K6_STRESS_ERROR_MAX   taux d'erreur de rupture        (défaut 5 %)
 *
 * Lancer : k6 run tests/k6/stress.js
 *          K6_STRESS_MAX_VUS=200 k6 run tests/k6/stress.js
 *
 * À observer pendant l'exécution : le palier où `http_req_duration` s'envole.
 */

import { envTexte, envNombre, STATS_RESUME } from './lib/config.js';
import {
  creerPersonne,
  emailUnique,
  lirePersonne,
  listerOrganisationsDeLaPersonne,
  listerPersonnes,
  nettoyerContexte,
  preparerContexte,
  rechercherParEmail,
  supprimerPersonne,
} from './lib/api.js';

const MAX_VUS = envNombre('K6_STRESS_MAX_VUS', 50);
const PALIER = envTexte('K6_STRESS_STEP', '30s');
const P95_MS = envNombre('K6_P95_STRESS_MS', 2000);
const ERREURS_MAX = envNombre('K6_STRESS_ERROR_MAX', 0.05);

// Quatre paliers réguliers puis retour à zéro. Découper la montée montre *où*
// ça casse ; une montée continue dirait juste « ça a cassé quelque part ».
const paliers = [1, 2, 3, 4].map((niveau) => ({
  duration: PALIER,
  target: Math.max(1, Math.round((MAX_VUS * niveau) / 4)),
}));

export const options = {
  summaryTrendStats: STATS_RESUME,
  scenarios: {
    stress: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [...paliers, { duration: PALIER, target: 0 }],
      gracefulRampDown: '15s',
    },
  },
  thresholds: {
    http_req_failed: [`rate<${ERREURS_MAX}`],
    'http_req_duration{endpoint:list_persons}': [`p(95)<${P95_MS}`],
    'http_req_duration{endpoint:search_person}': [`p(95)<${P95_MS}`],
    'http_req_duration{endpoint:create_person}': [`p(95)<${P95_MS}`],
  },
};

export function setup() {
  return preparerContexte();
}

// Sans pause : on cherche à saturer, pas à imiter un rythme humain. Une
// itération sur cinq écrit, pour ne pas tester que des lectures.
export default function (contexte) {
  listerPersonnes();
  lirePersonne(contexte.personneId);
  listerOrganisationsDeLaPersonne(contexte.personneId);
  rechercherParEmail(contexte.email);

  if (__ITER % 5 === 0) {
    const id = creerPersonne(emailUnique('k6-stress'));
    if (id !== null) {
      supprimerPersonne(id);
    }
  }
}

export function teardown(contexte) {
  nettoyerContexte(contexte);
}
