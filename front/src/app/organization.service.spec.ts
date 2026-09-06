import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { HttpErrorResponse } from '@angular/common/http';

import { OrganizationService } from './organization.service';
import { apiBaseUrl } from './config';
import { aPerson, anOrganization, embedded, tick } from './test-helpers';

describe('OrganizationService', () => {
  let service: OrganizationService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    });
    service = TestBed.inject(OrganizationService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  describe('fetchAll', () => {
    it('extrait la collection du document HAL', async () => {
      const promise = service.fetchAll();

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations`);
      expect(req.request.method).toBe('GET');
      req.flush(
        embedded('organizations', [anOrganization(), anOrganization({ id: 11, name: 'Acme' })]),
      );

      const orgs = await promise;
      expect(orgs).toHaveSize(2);
      expect(orgs[1].name).toBe('Acme');
    });

    it('rejette la promesse en propageant le statut HTTP du serveur', async () => {
      const promise = service.fetchAll();

      await tick();
      httpMock
        .expectOne(`${apiBaseUrl()}/organizations`)
        .flush('boom', { status: 503, statusText: 'Unavailable' });

      // On capture l'erreur au lieu de se contenter d'un rejet : le service ne
      // transforme pas l'erreur HTTP, l'appelant doit donc recevoir le statut.
      let caught: HttpErrorResponse | undefined;
      try {
        await promise;
      } catch (error) {
        caught = error as HttpErrorResponse;
      }

      expect(caught).toBeInstanceOf(HttpErrorResponse);
      expect(caught?.status).toBe(503);
    });
  });

  describe('fetchById', () => {
    it("récupère l'organisation puis complète ses membres en un second appel", async () => {
      const promise = service.fetchById(10);

      await tick();
      const orgReq = httpMock.expectOne(`${apiBaseUrl()}/organizations/10`);
      expect(orgReq.request.method).toBe('GET');
      orgReq.flush(anOrganization());

      await tick();

      httpMock
        .expectOne(`${apiBaseUrl()}/organizations/10/persons`)
        .flush(embedded('persons', [aPerson(), aPerson({ id: 2 })]));

      const org = await promise;
      expect(org.id).toBe(10);
      expect(org.persons).toHaveSize(2);
    });
  });

  describe('fetchOrganizationPersons', () => {
    it("interroge la sous-ressource persons de l'organisation", async () => {
      const promise = service.fetchOrganizationPersons(10);

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations/10/persons`);
      expect(req.request.method).toBe('GET');
      req.flush(embedded('persons', [aPerson({ id: 3 })]));

      expect((await promise)[0].id).toBe(3);
    });
  });

  describe('deleteById', () => {
    it('émet un DELETE sur la ressource', async () => {
      const promise = service.deleteById(10);

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations/10`);
      expect(req.request.method).toBe('DELETE');
      req.flush(null);

      await expectAsync(promise).toBeResolved();
    });
  });

  describe('save', () => {
    it("crée l'organisation en POST quand elle n'a pas d'identifiant", async () => {
      const promise = service.save(anOrganization({ id: undefined }));

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations`);
      expect(req.request.method).toBe('POST');
      expect(req.request.body).toEqual({ name: 'Orion Inc.' });
      req.flush(anOrganization({ id: 55 }));

      await tick();
      httpMock.expectOne(`${apiBaseUrl()}/organizations/55/persons`).flush(embedded('persons', []));

      const saved = await promise;
      expect(saved.id).toBe(55);
      expect(saved.persons).toEqual([]);
    });

    it("met à jour l'organisation en PUT quand elle a un identifiant", async () => {
      const promise = service.save(anOrganization({ id: 10, name: 'Orion SA' }));

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations/10`);
      expect(req.request.method).toBe('PUT');
      expect(req.request.body).toEqual({ name: 'Orion SA' });
      req.flush(anOrganization({ id: 10, name: 'Orion SA' }));

      await tick();
      httpMock
        .expectOne(`${apiBaseUrl()}/organizations/10/persons`)
        .flush(embedded('persons', [aPerson()]));

      const saved = await promise;
      expect(saved.name).toBe('Orion SA');
      expect(saved.persons).toHaveSize(1);
    });
  });

  describe('addPerson', () => {
    it('rattache une personne via le format text/uri-list attendu par Spring Data REST', async () => {
      const promise = service.addPerson(10, 7);

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations/10/persons`);
      expect(req.request.body).toBe(`${apiBaseUrl()}/persons/7`);
      expect(req.request.headers.get('Content-Type')).toBe('text/uri-list');
      req.flush(null);

      await expectAsync(promise).toBeResolved();
    });

    it('utilise POST, qui AJOUTE, et non PUT, qui remplace toute la liste', async () => {
      // La distinction n'est pas cosmétique. Sur un lien d'association, Spring
      // Data REST traite PUT comme un remplacement complet : rattacher une
      // personne en PUT évinçait tous les autres membres de l'organisation,
      // en répondant 204 comme si tout allait bien.
      // Comportement établi côté back par
      // OrganizationRestApiTest.AssociationEndpoints.
      const promise = service.addPerson(10, 7);

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations/10/persons`);
      expect(req.request.method).toBe('POST');
      req.flush(null);

      await promise;
    });

    it("propage l'erreur au lieu de la masquer", async () => {
      const promise = service.addPerson(10, 7);

      await tick();
      httpMock
        .expectOne(`${apiBaseUrl()}/organizations/10/persons`)
        .flush('boom', { status: 500, statusText: 'Server Error' });

      await expectAsync(promise).toBeRejected();
    });
  });

  describe('removePerson', () => {
    it("détache la personne par l'URL côté organisation", async () => {
      // Côté PROPRIÉTAIRE du many-to-many. L'URL symétrique
      // /persons/{id}/organizations/{id} vise le côté inverse (`mappedBy`),
      // qui n'écrit pas dans la table de jointure : le serveur répond 204 et
      // l'appartenance reste. Le bouton « retirer » ne faisait donc rien.
      const promise = service.removePerson(10, 7);

      await tick();
      const req = httpMock.expectOne(`${apiBaseUrl()}/organizations/10/persons/7`);
      expect(req.request.method).toBe('DELETE');
      req.flush(null);

      await expectAsync(promise).toBeResolved();
    });

    it("n'appelle jamais l'URL côté personne, sans effet sur l'association", async () => {
      const promise = service.removePerson(10, 7);

      await tick();
      httpMock.expectNone(`${apiBaseUrl()}/persons/7/organizations/10`);
      httpMock.expectOne(`${apiBaseUrl()}/organizations/10/persons/7`).flush(null);

      await promise;
    });

    it("propage l'erreur au lieu de la masquer", async () => {
      const promise = service.removePerson(10, 7);

      await tick();
      httpMock
        .expectOne(`${apiBaseUrl()}/organizations/10/persons/7`)
        .flush('boom', { status: 404, statusText: 'Not Found' });

      await expectAsync(promise).toBeRejected();
    });
  });
});
