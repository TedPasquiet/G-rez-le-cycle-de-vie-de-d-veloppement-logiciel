import { TestBed } from '@angular/core/testing';
import {
  HttpClientTestingModule,
  HttpTestingController,
} from '@angular/common/http/testing';

import { OrganizationService } from './organization.service';
import { API_BASE_URL } from './config';
import { aPerson, anOrganization, embedded, tick } from './test-helpers';

describe('OrganizationService', () => {
  let service: OrganizationService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule]
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
      const req = httpMock.expectOne(`${API_BASE_URL}/organizations`);
      expect(req.request.method).toBe('GET');
      req.flush(
        embedded('organizations', [
          anOrganization(),
          anOrganization({ id: 11, name: 'Acme' })
        ])
      );

      const orgs = await promise;
      expect(orgs.length).toBe(2);
      expect(orgs[1].name).toBe('Acme');
    });

    it('rejette la promesse si le serveur répond en erreur', async () => {
      const promise = service.fetchAll();

      await tick();
      httpMock
        .expectOne(`${API_BASE_URL}/organizations`)
        .flush('boom', { status: 503, statusText: 'Unavailable' });

      await expectAsync(promise).toBeRejected();
    });
  });

  describe('fetchById', () => {
    it("récupère l'organisation puis complète ses membres en un second appel", async () => {
      const promise = service.fetchById(10);

      await tick();
      const orgReq = httpMock.expectOne(`${API_BASE_URL}/organizations/10`);
      expect(orgReq.request.method).toBe('GET');
      orgReq.flush(anOrganization());

      await tick();

      httpMock
        .expectOne(`${API_BASE_URL}/organizations/10/persons`)
        .flush(embedded('persons', [aPerson(), aPerson({ id: 2 })]));

      const org = await promise;
      expect(org.id).toBe(10);
      expect(org.persons.length).toBe(2);
    });
  });

  describe('fetchOrganizationPersons', () => {
    it("interroge la sous-ressource persons de l'organisation", async () => {
      const promise = service.fetchOrganizationPersons(10);

      await tick();
      const req = httpMock.expectOne(
        `${API_BASE_URL}/organizations/10/persons`
      );
      expect(req.request.method).toBe('GET');
      req.flush(embedded('persons', [aPerson({ id: 3 })]));

      expect((await promise)[0].id).toBe(3);
    });
  });

  describe('deleteById', () => {
    it('émet un DELETE sur la ressource', async () => {
      const promise = service.deleteById(10);

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/organizations/10`);
      expect(req.request.method).toBe('DELETE');
      req.flush(null);

      await expectAsync(promise).toBeResolved();
    });
  });

  describe('save', () => {
    it("crée l'organisation en POST quand elle n'a pas d'identifiant", async () => {
      const promise = service.save(anOrganization({ id: undefined }));

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/organizations`);
      expect(req.request.method).toBe('POST');
      expect(req.request.body).toEqual({ name: 'Orion Inc.' });
      req.flush(anOrganization({ id: 55 }));

      await tick();
      httpMock
        .expectOne(`${API_BASE_URL}/organizations/55/persons`)
        .flush(embedded('persons', []));

      const saved = await promise;
      expect(saved.id).toBe(55);
      expect(saved.persons).toEqual([]);
    });

    it("met à jour l'organisation en PUT quand elle a un identifiant", async () => {
      const promise = service.save(anOrganization({ id: 10, name: 'Orion SA' }));

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/organizations/10`);
      expect(req.request.method).toBe('PUT');
      expect(req.request.body).toEqual({ name: 'Orion SA' });
      req.flush(anOrganization({ id: 10, name: 'Orion SA' }));

      await tick();
      httpMock
        .expectOne(`${API_BASE_URL}/organizations/10/persons`)
        .flush(embedded('persons', [aPerson()]));

      const saved = await promise;
      expect(saved.name).toBe('Orion SA');
      expect(saved.persons.length).toBe(1);
    });
  });

  describe('addPerson', () => {
    it("rattache une personne via le format text/uri-list attendu par Spring Data REST", async () => {
      const promise = service.addPerson(10, 7);

      await tick();
      const req = httpMock.expectOne(
        `${API_BASE_URL}/organizations/10/persons`
      );
      expect(req.request.method).toBe('PUT');
      expect(req.request.body).toBe(`${API_BASE_URL}/persons/7`);
      expect(req.request.headers.get('Content-Type')).toBe('text/uri-list');
      req.flush(null);

      await expectAsync(promise).toBeResolved();
    });
  });

  describe('removePerson', () => {
    it("détache la personne via la sous-ressource organizations de la personne", async () => {
      const promise = service.removePerson(10, 7);

      // Le détachement passe par le côté "person" de l'association, alors que
      // le rattachement passe par le côté "organization" : dissymétrie voulue
      // par l'API Spring Data REST.
      await tick();
      const req = httpMock.expectOne(
        `${API_BASE_URL}/persons/7/organizations/10`
      );
      expect(req.request.method).toBe('DELETE');
      req.flush(null);

      await expectAsync(promise).toBeResolved();
    });
  });
});
