import { HttpErrorResponse } from '@angular/common/http';
import { TestBed } from '@angular/core/testing';

import { HttpErrorService } from './http-error.service';

/** Fabrique une réponse d'erreur telle que `HttpClient` la produirait. */
const uneErreur = (status: number, url = 'http://localhost:8080/persons') =>
  new HttpErrorResponse({ status, url, statusText: 'erreur simulée' });

describe('HttpErrorService', () => {
  let service: HttpErrorService;

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(HttpErrorService);
  });

  it("ne signale rien tant qu'aucune requête n'a échoué", () => {
    expect(service.failure()).toBeNull();
  });

  it("retient le statut, la méthode et l'URL de la requête en échec", () => {
    service.report(uneErreur(500, 'http://localhost:8080/organizations/10'), 'DELETE');

    const echec = service.failure();
    expect(echec?.status).toBe(500);
    expect(echec?.method).toBe('DELETE');
    expect(echec?.url).toBe('http://localhost:8080/organizations/10');
  });

  /**
   * Le cœur du besoin : ces deux situations envoient chercher la panne à des
   * endroits différents. Un message unique du genre « une erreur est survenue »
   * ferait perdre exactement le temps que ce mécanisme existe pour économiser.
   */
  it('distingue une requête qui n’a jamais atteint le serveur d’une réponse d’erreur', () => {
    service.report(uneErreur(0), 'GET');
    const reseau = service.failure();

    service.report(uneErreur(500), 'GET');
    const serveur = service.failure();

    expect(reseau?.title).toBe('Server unreachable');
    expect(reseau?.detail).toContain('CORS');
    expect(serveur?.title).not.toBe(reseau?.title);
    expect(serveur?.detail).not.toBe(reseau?.detail);
  });

  it('affiche le statut dans le titre des réponses d’erreur du serveur', () => {
    service.report(uneErreur(503), 'GET');
    expect(service.failure()?.title).toBe('Server error (HTTP 503)');

    service.report(uneErreur(404), 'GET');
    expect(service.failure()?.title).toBe('Request rejected (HTTP 404)');
  });

  /**
   * Le back renvoie 403 sur une origine CORS non autorisée. Sans ce rappel
   * dans le message, un 403 se lit comme un problème de droits et on cherche
   * au mauvais endroit — c'est arrivé sur ce projet.
   */
  it('mentionne la piste CORS dans le message du 403', () => {
    service.report(uneErreur(403), 'POST');

    const echec = service.failure();
    expect(echec?.title).toBe('Request rejected (HTTP 403)');
    expect(echec?.detail).toContain('CORS');
  });

  it('remplace « null » par une mention lisible quand l’URL est inconnue', () => {
    service.report(new HttpErrorResponse({ status: 0 }), 'GET');

    expect(service.failure()?.url).toBe('unknown URL');
  });

  it('oublie l’échec quand on l’efface', () => {
    service.report(uneErreur(500), 'GET');
    service.clear();

    expect(service.failure()).toBeNull();
  });

  it('ne garde que le dernier échec', () => {
    service.report(uneErreur(500), 'GET');
    service.report(uneErreur(404, 'http://localhost:8080/persons/9'), 'PUT');

    expect(service.failure()?.status).toBe(404);
    expect(service.failure()?.method).toBe('PUT');
  });
});
