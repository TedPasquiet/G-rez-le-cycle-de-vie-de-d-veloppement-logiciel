import {
  DEFAULT_API_BASE_URL,
  apiBaseUrl,
  chargeConfigurationExecution,
  reinitialiseConfiguration,
} from './config';

/**
 * Fabrique une fausse implémentation de `fetch`.
 *
 * On ne passe pas par HttpTestingController : `chargeConfigurationExecution`
 * s'exécute AVANT le démarrage d'Angular, donc hors de toute injection de
 * dépendances. Elle accepte pour cette raison une implémentation de `fetch` en
 * paramètre, ce qui la rend testable sans infrastructure.
 */
const fauxFetch = (corps: string, options: { statut?: number; type?: string } = {}) =>
  (() =>
    Promise.resolve(
      new Response(corps, {
        status: options.statut ?? 200,
        headers: { 'Content-Type': options.type ?? 'application/json' },
      }),
    )) as unknown as typeof fetch;

const fetchQuiEchoue = (() =>
  Promise.reject(new TypeError('Failed to fetch'))) as unknown as typeof fetch;

describe('config', () => {
  beforeEach(() => reinitialiseConfiguration());
  afterEach(() => reinitialiseConfiguration());

  it("part sur l'URL par défaut tant que rien n'est chargé", () => {
    expect(apiBaseUrl()).toBe(DEFAULT_API_BASE_URL);
  });

  describe('quand aucune configuration n’est servie', () => {
    it('retombe sur le défaut si le réseau échoue', async () => {
      await chargeConfigurationExecution(fetchQuiEchoue);
      expect(apiBaseUrl()).toBe(DEFAULT_API_BASE_URL);
    });

    it('retombe sur le défaut sur une 404', async () => {
      await chargeConfigurationExecution(fauxFetch('introuvable', { statut: 404 }));
      expect(apiBaseUrl()).toBe(DEFAULT_API_BASE_URL);
    });

    it("retombe sur le défaut quand le serveur de dev renvoie l'index.html", async () => {
      // `ng serve` répond 200 + text/html pour toute route inconnue : ce cas ne
      // doit surtout pas être traité comme une configuration illisible.
      await chargeConfigurationExecution(
        fauxFetch('<!doctype html><html></html>', { type: 'text/html; charset=utf-8' }),
      );
      expect(apiBaseUrl()).toBe(DEFAULT_API_BASE_URL);
    });
  });

  describe('quand une configuration est servie', () => {
    it("utilise l'URL fournie", async () => {
      await chargeConfigurationExecution(
        fauxFetch('{"apiBaseUrl":"https://api.microcrm.staging.example.com"}'),
      );
      expect(apiBaseUrl()).toBe('https://api.microcrm.staging.example.com');
    });

    it('retire les / finaux pour éviter les doubles slashes', async () => {
      await chargeConfigurationExecution(fauxFetch('{"apiBaseUrl":"https://api.example.com//"}'));
      expect(apiBaseUrl()).toBe('https://api.example.com');
    });
  });

  describe('quand la configuration servie est illisible', () => {
    // Un repli silencieux vers localhost serait ici la pire des issues : c'est
    // exactement la panne que ce mécanisme existe pour supprimer.

    it('lève une erreur explicite si le JSON est invalide', async () => {
      await expectAsync(
        chargeConfigurationExecution(fauxFetch('{ ceci n est pas du json')),
      ).toBeRejectedWithError(/pas du JSON valide/);
    });

    it('lève une erreur explicite si apiBaseUrl est absente', async () => {
      await expectAsync(
        chargeConfigurationExecution(fauxFetch('{"autreCle":"valeur"}')),
      ).toBeRejectedWithError(/absente ou vide/);
    });

    it('lève une erreur explicite si apiBaseUrl est vide', async () => {
      await expectAsync(
        chargeConfigurationExecution(fauxFetch('{"apiBaseUrl":"   "}')),
      ).toBeRejectedWithError(/absente ou vide/);
    });

    it("lève une erreur explicite si l'URL n'est pas absolue", async () => {
      await expectAsync(
        chargeConfigurationExecution(fauxFetch('{"apiBaseUrl":"/api"}')),
      ).toBeRejectedWithError(/URL absolue/);
    });
  });
});
