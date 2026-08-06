/**
 * Configuration d'exécution du front.
 *
 * Le problème résolu ici est celui décrit dans VARIABILISATION.md §5 : l'URL de
 * l'API était une constante littérale, donc *compilée dans le bundle* par
 * `ng build`. Une image par environnement, ou une image de production qui
 * appelle `localhost` — dans les deux cas on perd le « build once » des douze
 * facteurs.
 *
 * La valeur est désormais lue **au démarrage de l'application**, dans un
 * fichier `config.json` servi par Caddy. Caddy le fabrique à la volée à partir
 * de son environnement (`front/Caddyfile`, directive `respond`), donc la même
 * image sert en local, en staging et en production ; seule la variable
 * `FRONT_API_BASE_URL` du conteneur change.
 *
 * Le comportement suit le motif posé par `tests/k6/lib/config.js`, cité en §3
 * de VARIABILISATION.md comme la référence du dépôt :
 *
 *   1. un défaut utilisable sans aucune configuration — `ng serve` et
 *      `docker compose up` fonctionnent tels quels ;
 *   2. une surcharge par environnement ;
 *   3. une **erreur explicite** si la valeur fournie est illisible, plutôt
 *      qu'un repli silencieux.
 *
 * La distinction du point 3 est volontaire et mérite d'être comprise :
 *
 *   - `config.json` **absent** (404, ou l'`index.html` que renvoie le serveur
 *     de développement Angular pour toute route inconnue) est une situation
 *     normale en développement : on retombe sur le défaut, avec une trace en
 *     console.
 *   - `config.json` **présent mais inexploitable** est un défaut de
 *     déploiement. Retomber silencieusement sur `http://localhost:8080` y
 *     serait le pire des comportements : c'est précisément la panne que ce
 *     mécanisme existe pour supprimer, et elle serait invisible. On lève donc
 *     une erreur.
 */

/**
 * Valeur de repli, utilisée quand aucune configuration n'est servie. C'est
 * l'adresse du back de la stack locale (`docker-compose.yml`, `BACK_PORT`).
 */
export const DEFAULT_API_BASE_URL = 'http://localhost:8080';

/** Chemin relatif : l'application doit rester servie derrière n'importe quel hôte. */
const CONFIG_URL = 'config.json';

let apiBaseUrlCourante: string = DEFAULT_API_BASE_URL;

/**
 * URL de base de l'API.
 *
 * C'est une fonction et non une constante : la valeur n'est connue qu'après
 * `chargeConfigurationExecution()`, alors qu'une constante exportée serait
 * figée à l'import du module.
 */
export const apiBaseUrl = (): string => apiBaseUrlCourante;

/** Remet la valeur par défaut. Réservé aux tests. */
export const reinitialiseConfiguration = (): void => {
  apiBaseUrlCourante = DEFAULT_API_BASE_URL;
};

/**
 * Valide une URL d'API et retire les `/` finaux : les services concatènent
 * `${apiBaseUrl()}/persons`, une valeur terminée par `/` produirait `//persons`.
 */
const valideUrl = (valeur: unknown): string => {
  if (typeof valeur !== 'string' || valeur.trim() === '') {
    throw new Error(
      `Configuration du front invalide : « apiBaseUrl » est absente ou vide dans ${CONFIG_URL}. ` +
        "Vérifier la variable d'environnement FRONT_API_BASE_URL du conteneur.",
    );
  }

  const nettoyee = valeur.trim().replace(/\/+$/, '');
  if (!/^https?:\/\/.+/.test(nettoyee)) {
    throw new Error(
      `Configuration du front invalide : « apiBaseUrl » vaut « ${valeur} », ` +
        'or une URL absolue commençant par http:// ou https:// est attendue.',
    );
  }
  return nettoyee;
};

/**
 * Charge la configuration d'exécution. À appeler **avant** de démarrer
 * l'application (voir `src/main.ts`).
 *
 * @param fetchImpl injectable pour les tests ; `fetch` du navigateur par défaut.
 */
export const chargeConfigurationExecution = async (
  fetchImpl: typeof fetch = fetch,
): Promise<string> => {
  let reponse: Response;
  try {
    reponse = await fetchImpl(CONFIG_URL, { cache: 'no-store' });
  } catch {
    // Pas de serveur, ou requête bloquée : on est en développement.
    console.info(
      `[config] ${CONFIG_URL} injoignable, utilisation du défaut ${DEFAULT_API_BASE_URL}`,
    );
    apiBaseUrlCourante = DEFAULT_API_BASE_URL;
    return apiBaseUrlCourante;
  }

  // Le serveur de développement Angular renvoie `index.html` (en HTTP 200) pour
  // toute route inconnue : sans le contrôle du type de contenu, on tenterait
  // d'analyser du HTML comme du JSON et on lèverait une erreur à tort.
  const typeContenu = reponse.headers.get('content-type') ?? '';
  if (!reponse.ok || !typeContenu.includes('application/json')) {
    console.info(
      `[config] aucun ${CONFIG_URL} servi, utilisation du défaut ${DEFAULT_API_BASE_URL}`,
    );
    apiBaseUrlCourante = DEFAULT_API_BASE_URL;
    return apiBaseUrlCourante;
  }

  // À partir d'ici le fichier existe et s'annonce comme du JSON : toute anomalie
  // est un défaut de déploiement, pas un cas de développement.
  let contenu: unknown;
  try {
    contenu = await reponse.json();
  } catch (cause) {
    throw new Error(
      `Configuration du front illisible : ${CONFIG_URL} est servi mais n'est pas du JSON valide.`,
      { cause },
    );
  }

  const { apiBaseUrl: valeur } = (contenu ?? {}) as { apiBaseUrl?: unknown };
  apiBaseUrlCourante = valideUrl(valeur);
  return apiBaseUrlCourante;
};
