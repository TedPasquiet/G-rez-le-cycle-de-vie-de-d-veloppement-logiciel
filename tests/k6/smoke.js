/**
 * smoke.js — test de fumée.
 *
 * Un seul utilisateur, quelques secondes : « est-ce que ça marche encore ? ».
 * Ce n'est pas un test de charge. C'est le seul scénario bloquant dans la CI,
 * parce qu'il est court, stable, et qu'une erreur ici est un vrai problème.
 *
 *   K6_SMOKE_ITERATIONS   nombre de parcours joués  (défaut 5)
 *   K6_P95_SMOKE_MS       budget p95 en ms          (défaut 1500)
 *
 * Budget large : le test tourne juste après le démarrage, quand la JVM n'a
 * rien optimisé. Les vrais seuils de temps de réponse sont dans load.js.
 *
 * Lancer : k6 run tests/k6/smoke.js
 */

import { group } from 'k6';
import { envNombre, STATS_RESUME } from './lib/config.js';
import {
  creerPersonne,
  emailUnique,
  lirePersonne,
  listerOrganisations,
  listerOrganisationsDeLaPersonne,
  listerPersonnes,
  nettoyerContexte,
  preparerContexte,
  rechercherParEmail,
  supprimerPersonne,
} from './lib/api.js';

const P95_MS = envNombre('K6_P95_SMOKE_MS', 1500);

export const options = {
  vus: 1,
  iterations: envNombre('K6_SMOKE_ITERATIONS', 5),
  summaryTrendStats: STATS_RESUME,
  thresholds: {
    // Aucune tolérance : sur un seul utilisateur, la moindre erreur veut dire
    // que quelque chose est cassé.
    http_req_failed: ['rate==0'],
    checks: ['rate==1.00'],
    // Une lecture et une écriture suffisent ici ; départager les endpoints est
    // le rôle de load.js.
    'http_req_duration{endpoint:list_persons}': [`p(95)<${P95_MS}`],
    'http_req_duration{endpoint:create_person}': [`p(95)<${P95_MS}`],
  },
};

export function setup() {
  return preparerContexte();
}

export default function (contexte) {
  group('lecture', () => {
    listerPersonnes();
    lirePersonne(contexte.personneId);
    listerOrganisationsDeLaPersonne(contexte.personneId);
    listerOrganisations();
    rechercherParEmail(contexte.email);
  });

  // Cycle de vie complet d'une fiche : sans écriture, une base cassée en
  // insertion passerait inaperçue.
  group('écriture', () => {
    const id = creerPersonne(emailUnique('k6-smoke'));
    if (id !== null) {
      lirePersonne(id);
      supprimerPersonne(id);
    }
  });
}

export function teardown(contexte) {
  nettoyerContexte(contexte);
}
