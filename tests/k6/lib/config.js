/**
 * config.js — réglages partagés par les trois scénarios k6.
 *
 * Tout passe par des variables d'environnement : le même fichier sert en local
 * et en CI sans être modifié.
 *
 *   K6_BASE_URL          URL de l'API                   (défaut http://localhost:8080)
 *   K6_READY_TIMEOUT_S   attente max au démarrage       (défaut 60 s)
 *   K6_P95_READ_MS       budget p95 des lectures        (défaut 500 ms)
 *   K6_P95_WRITE_MS      budget p95 des écritures       (défaut 800 ms)
 *   K6_ERROR_RATE_MAX    part max de requêtes en erreur (défaut 1 %)
 *
 * Les réglages propres à un scénario (VUs, durées) sont en tête de son fichier.
 */

// Une variable illisible (faute de frappe) doit échouer tout de suite : sinon
// on obtient NaN, k6 démarre quand même, et la mesure est fausse sans le dire.
export function envNombre(nom, defaut) {
  const brut = __ENV[nom];
  if (brut === undefined || brut === '') {
    return defaut;
  }
  const valeur = Number(brut);
  if (Number.isNaN(valeur)) {
    throw new Error(`${nom} doit être un nombre, reçu : '${brut}'`);
  }
  return valeur;
}

// Sert pour les URLs et pour les durées : en k6 une durée est une chaîne
// ('30s', '2m'), pas un nombre — il n'y a donc rien à convertir.
export function envTexte(nom, defaut) {
  const brut = __ENV[nom];
  return brut === undefined || brut === '' ? defaut : brut;
}

// Le replace enlève le '/' final, sinon on construit des URLs en '//persons'.
export const BASE_URL = envTexte('K6_BASE_URL', 'http://localhost:8080').replace(/\/+$/, '');

export const READY_TIMEOUT_S = envNombre('K6_READY_TIMEOUT_S', 60);

// Le budget performance : c'est lui qui fait du test un garde-fou. Dépassement
// = k6 sort en 99 = job CI rouge.
//
// p95 et pas moyenne : une moyenne correcte peut cacher 5 % d'utilisateurs à
// 4 secondes. Lecture et écriture séparées : un INSERT est structurellement
// plus lent qu'un SELECT.
export const SLO = {
  p95LectureMs: envNombre('K6_P95_READ_MS', 500),
  p95EcritureMs: envNombre('K6_P95_WRITE_MS', 800),
  tauxErreurMax: envNombre('K6_ERROR_RATE_MAX', 0.01),
};

// J'ajoute le p(99) aux stats par défaut : une dégradation s'y voit avant de
// gagner le p95.
export const STATS_RESUME = ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'];
