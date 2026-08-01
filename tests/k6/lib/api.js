/**
 * api.js — client de l'API MicroCRM pour les scénarios k6.
 *
 * Les trois scénarios tapent sur les mêmes endpoints : URLs et vérifications
 * sont écrites ici une seule fois.
 *
 * Deux partis pris :
 *  - chaque appel porte un tag `endpoint`, ce qui permet un seuil et des
 *    statistiques par endpoint (sinon une moyenne globale cache le lent) ;
 *  - chaque appel est vérifié fonctionnellement (`check`) : un serveur qui
 *    répond « 500 » en 3 ms est rapide et cassé.
 */

import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { BASE_URL, READY_TIMEOUT_S } from './config.js';

// `Accept` n'est pas décoratif : Spring Data REST ne renvoie le corps de la
// ressource créée (POST) que si le client en demande un. Le front Angular
// l'envoie, on fait pareil.
const ENTETES_LECTURE = { Accept: 'application/json' };
const ENTETES_ECRITURE = { Accept: 'application/json', 'Content-Type': 'application/json' };

// --------------------------------------------------------------------------
// Utilitaires internes
// --------------------------------------------------------------------------

// Ne fait pas planter le VU si la réponse n'est pas du JSON (erreur HTML,
// corps vide, connexion coupée).
function corpsJson(reponse) {
  try {
    return reponse.json();
  } catch (erreur) {
    return null;
  }
}

// Le nom du check s'affiche tel quel dans le résumé de fin : autant qu'il soit
// lisible.
function verifier(reponse, endpoint, statutsAttendus, conditionCorps) {
  const controles = {
    [`${endpoint} → statut ${statutsAttendus.join('/')}`]: (r) =>
      statutsAttendus.includes(r.status),
  };
  if (conditionCorps) {
    controles[`${endpoint} → corps attendu`] = (r) =>
      statutsAttendus.includes(r.status) && conditionCorps(corpsJson(r));
  }
  return check(reponse, controles);
}

function get(chemin, endpoint) {
  return http.get(`${BASE_URL}${chemin}`, { headers: ENTETES_LECTURE, tags: { endpoint } });
}

// --------------------------------------------------------------------------
// Préparation (appelée depuis setup)
// --------------------------------------------------------------------------

/**
 * Attend que l'API réponde et renvoie le corps de la première réponse réussie.
 *
 * En CI le conteneur démarre en même temps que le job : sans cette attente le
 * test échouerait pour une mauvaise raison (l'appli n'est pas lente, elle
 * n'est pas encore là).
 *
 * `responseCallback` marque ces requêtes comme normales quel que soit leur
 * statut : les tentatives ratées pendant le démarrage ne faussent donc pas le
 * taux d'erreur du test.
 */
export function attendreApiPrete() {
  const parametres = {
    headers: ENTETES_LECTURE,
    timeout: '2s',
    tags: { endpoint: 'readiness' },
    responseCallback: http.expectedStatuses({ min: 0, max: 599 }),
  };

  // Deadline sur le temps réellement écoulé, pas sur un nombre de tentatives :
  // une tentative peut durer jusqu'à 3 s (2 s de timeout + 1 s de pause), donc
  // compter les tours donnerait un délai bien plus long que celui annoncé.
  const limite = Date.now() + READY_TIMEOUT_S * 1000;
  do {
    const reponse = http.get(`${BASE_URL}/persons`, parametres);
    if (reponse.status === 200) {
      return corpsJson(reponse);
    }
    sleep(1);
  } while (Date.now() < limite);

  // `fail` lève une exception : rien ne s'exécute après.
  fail(`API injoignable sur ${BASE_URL} après ${READY_TIMEOUT_S}s — test annulé`);
}

/**
 * Repère une personne existante qui servira de cible aux lectures. Réutilise la
 * réponse de l'attente ci-dessus pour ne pas ajouter une requête dans les
 * statistiques. Base vide : on crée la personne et on la supprimera à la fin.
 *
 * La valeur renvoyée est passée par k6 à chaque VU et à `teardown()`.
 */
export function preparerContexte() {
  const corps = attendreApiPrete();
  const personnes = corps?._embedded?.persons ?? [];

  if (personnes.length > 0) {
    return { personneId: personnes[0].id, email: personnes[0].email, creeParLeTest: false };
  }

  const email = emailUnique('k6-ref');
  const id = creerPersonne(email);
  if (id === null) {
    fail('Impossible de créer la personne de référence — test annulé');
  }
  return { personneId: id, email, creeParLeTest: true };
}

// On ne supprime que ce que le test a créé : jamais les données déjà présentes.
export function nettoyerContexte(contexte) {
  if (contexte?.creeParLeTest) {
    supprimerPersonne(contexte.personneId);
  }
}

// --------------------------------------------------------------------------
// Lectures
// --------------------------------------------------------------------------

export function listerPersonnes() {
  const reponse = get('/persons?page=0&size=20', 'list_persons');
  verifier(reponse, 'GET /persons', [200], (corps) => Array.isArray(corps?._embedded?.persons));
  return reponse;
}

export function lirePersonne(id) {
  const reponse = get(`/persons/${id}`, 'read_person');
  verifier(reponse, 'GET /persons/{id}', [200], (corps) => corps?.id !== undefined);
  return reponse;
}

export function listerOrganisationsDeLaPersonne(id) {
  const reponse = get(`/persons/${id}/organizations`, 'person_orgs');
  verifier(reponse, 'GET /persons/{id}/organizations', [200], (corps) =>
    Array.isArray(corps?._embedded?.organizations),
  );
  return reponse;
}

export function listerOrganisations() {
  const reponse = get('/organizations?page=0&size=20', 'list_orgs');
  verifier(reponse, 'GET /organizations', [200], (corps) =>
    Array.isArray(corps?._embedded?.organizations),
  );
  return reponse;
}

// La requête la plus coûteuse côté base, donc celle qui décroche en premier
// sous charge : elle a sa place dans le parcours de lecture.
//
// On n'accepte que 200 : la personne cherchée est celle de `preparerContexte`,
// elle existe donc toujours. Tolérer un 404 ici serait incohérent avec le
// seuil `http_req_failed`, qui compte de toute façon les 4xx comme des échecs.
export function rechercherParEmail(email) {
  const reponse = get(
    `/persons/search/findByEmail?email=${encodeURIComponent(email)}`,
    'search_person',
  );
  verifier(reponse, 'GET /persons/search/findByEmail', [200]);
  return reponse;
}

// --------------------------------------------------------------------------
// Écritures
// --------------------------------------------------------------------------

// L'email doit être unique : la colonne a une contrainte d'unicité, deux VUs
// avec le même email provoqueraient une fausse erreur.
export function creerPersonne(email) {
  const charge = JSON.stringify({
    firstName: 'Perf',
    lastName: 'Tester',
    email,
    phone: '0102030405',
    bio: 'Personne créée par un test de charge k6',
  });

  const reponse = http.post(`${BASE_URL}/persons`, charge, {
    headers: ENTETES_ECRITURE,
    tags: { endpoint: 'create_person' },
  });
  verifier(reponse, 'POST /persons', [201], (corps) => corps?.id !== undefined);

  return identifiantCree(reponse);
}

// Corps de la réponse d'abord ; s'il est vide (configurable côté Spring Data
// REST) on se rabat sur l'en-tête `Location`, toujours présent avec un 201.
function identifiantCree(reponse) {
  const id = corpsJson(reponse)?.id;
  if (id !== undefined && id !== null) {
    return id;
  }

  const location = reponse.headers['Location'];
  const trouve = location ? /\/(\d+)$/.exec(location) : null;
  return trouve ? Number(trouve[1]) : null;
}

// On supprime ce qu'on crée : sinon la base grossit à chaque exécution et les
// mesures ne sont plus comparables d'un run à l'autre.
export function supprimerPersonne(id) {
  const reponse = http.del(`${BASE_URL}/persons/${id}`, null, {
    headers: ENTETES_LECTURE,
    tags: { endpoint: 'delete_person' },
  });
  verifier(reponse, 'DELETE /persons/{id}', [200, 204]);
  return reponse;
}

// --------------------------------------------------------------------------
// Divers
// --------------------------------------------------------------------------

// Volontairement sans `__VU` / `__ITER` : ces variables n'existent que dans le
// contexte d'un VU, et cette fonction est aussi appelée depuis setup(), où
// elles lèveraient une ReferenceError. Horodatage + aléa suffisent à garantir
// l'unicité (la colonne email porte une contrainte d'unicité en base).
export function emailUnique(prefixe = 'k6') {
  const alea = Math.random().toString(36).slice(2, 10);
  return `${prefixe}-${Date.now()}-${alea}@example.net`;
}

// Imite le temps de lecture d'un vrai utilisateur. Sans pause, on mesure
// surtout la capacité du générateur de charge.
export function pauseUtilisateur(min = 0.5, max = 1.5) {
  sleep(min + Math.random() * (max - min));
}
