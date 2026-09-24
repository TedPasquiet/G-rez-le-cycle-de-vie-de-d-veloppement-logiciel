import { HttpClient, HttpRequest, provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { firstValueFrom, throwError } from 'rxjs';

import { httpErrorInterceptor } from './http-error.interceptor';
import { HttpErrorService } from './http-error.service';

describe('httpErrorInterceptor', () => {
  let http: HttpClient;
  let controleur: HttpTestingController;
  let journal: HttpErrorService;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([httpErrorInterceptor])),
        provideHttpClientTesting(),
      ],
    });

    http = TestBed.inject(HttpClient);
    controleur = TestBed.inject(HttpTestingController);
    journal = TestBed.inject(HttpErrorService);
  });

  afterEach(() => controleur.verify());

  it('ne signale rien quand la requête aboutit', async () => {
    const promesse = firstValueFrom(http.get('/persons'));
    controleur.expectOne('/persons').flush({ ok: true });
    await promesse;

    expect(journal.failure()).toBeNull();
  });

  /**
   * Le cas des quatre pannes du projet : la requête n'atteint jamais le
   * serveur (CORS, port fermé, http au lieu de https), le navigateur rapporte
   * un statut 0 et, jusqu'ici, l'écran ne bougeait pas d'un pixel.
   */
  it("signale une requête bloquée avant d'atteindre le serveur", async () => {
    const promesse = firstValueFrom(http.get('http://api.example/persons'));
    controleur
      .expectOne('http://api.example/persons')
      .error(new ProgressEvent('error'), { status: 0 });
    await expectAsync(promesse).toBeRejected();

    const echec = journal.failure();
    expect(echec?.status).toBe(0);
    expect(echec?.method).toBe('GET');
    expect(echec?.title).toBe('Server unreachable');
  });

  it("signale une réponse d'erreur du serveur avec son verbe HTTP", async () => {
    const promesse = firstValueFrom(http.post('/organizations/1/persons', 'x'));
    controleur
      .expectOne('/organizations/1/persons')
      .flush('nope', { status: 403, statusText: 'Forbidden' });
    await expectAsync(promesse).toBeRejected();

    const echec = journal.failure();
    expect(echec?.status).toBe(403);
    expect(echec?.method).toBe('POST');
  });

  /**
   * Un intercepteur qui absorberait l'erreur recréerait le défaut un cran plus
   * loin : l'appelant verrait un succès, et les composants ne pourraient plus
   * distinguer « liste vide » de « chargement échoué ».
   */
  it("relance l'erreur au lieu de l'absorber", async () => {
    const promesse = firstValueFrom(http.get('/persons'));
    controleur.expectOne('/persons').flush(null, { status: 500, statusText: 'Boom' });

    await expectAsync(promesse).toBeRejected();
  });

  /**
   * Effacer l'échec dès qu'une requête réussit serait tentant, et faux : le
   * tableau de bord lance deux requêtes en parallèle, et la réussite de l'une
   * effacerait l'échec de l'autre avant qu'on ait eu le temps de le lire. On
   * retomberait sur « rien ne se passe », à une fraction de seconde près.
   */
  it("ne laisse pas une requête réussie effacer l'échec d'une autre", async () => {
    const perdue = firstValueFrom(http.get('/persons'));
    const reussie = firstValueFrom(http.get('/organizations'));

    controleur.expectOne('/persons').flush(null, { status: 500, statusText: 'Boom' });
    await expectAsync(perdue).toBeRejected();

    controleur.expectOne('/organizations').flush({ ok: true });
    await reussie;

    expect(journal.failure()?.status).toBe(500);
  });

  /**
   * Une erreur qui n'est pas une réponse HTTP — levée par un intercepteur voisin
   * ou par un opérateur en aval — n'a ni statut ni URL. La présenter comme une
   * panne réseau serait un mensonge utile à personne.
   */
  it("laisse passer sans la signaler une erreur qui n'est pas une réponse HTTP", async () => {
    const panne = new Error('intercepteur en aval');

    const flux = TestBed.runInInjectionContext(() =>
      httpErrorInterceptor(new HttpRequest('GET', '/persons'), () => throwError(() => panne)),
    );

    await expectAsync(firstValueFrom(flux)).toBeRejectedWith(panne);
    expect(journal.failure()).toBeNull();
  });
});
