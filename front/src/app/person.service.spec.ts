import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { HttpErrorResponse } from '@angular/common/http';

import { PersonService } from './person.service';
import { API_BASE_URL } from './config';
import { aPerson, anOrganization, embedded, tick } from './test-helpers';

describe('PersonService', () => {
  let service: PersonService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    });
    service = TestBed.inject(PersonService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    // Échoue si une requête a été émise sans que le test l'attende.
    httpMock.verify();
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  describe('fetchAll', () => {
    it('extrait la collection du document HAL renvoyé par Spring Data REST', async () => {
      const promise = service.fetchAll();

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/persons`);
      expect(req.request.method).toBe('GET');
      req.flush(embedded('persons', [aPerson(), aPerson({ id: 2 })]));

      const persons = await promise;
      expect(persons).toHaveSize(2);
      expect(persons[0].firstName).toBe('John');
    });

    it('retourne une liste vide quand le serveur ne renvoie aucune personne', async () => {
      const promise = service.fetchAll();

      await tick();
      httpMock.expectOne(`${API_BASE_URL}/persons`).flush(embedded('persons', []));

      expect(await promise).toEqual([]);
    });

    it('rejette la promesse en propageant le statut HTTP du serveur', async () => {
      const promise = service.fetchAll();

      await tick();
      httpMock
        .expectOne(`${API_BASE_URL}/persons`)
        .flush('boom', { status: 500, statusText: 'Server Error' });

      // On capture l'erreur au lieu de se contenter d'un rejet : le service ne
      // transforme pas l'erreur HTTP, l'appelant doit donc recevoir le statut.
      let caught: HttpErrorResponse | undefined;
      try {
        await promise;
      } catch (error) {
        caught = error as HttpErrorResponse;
      }

      expect(caught).toBeInstanceOf(HttpErrorResponse);
      expect(caught?.status).toBe(500);
    });
  });

  describe('fetchById', () => {
    it('récupère la personne puis complète ses organisations en un second appel', async () => {
      const promise = service.fetchById(1);

      await tick();
      const personReq = httpMock.expectOne(`${API_BASE_URL}/persons/1`);
      expect(personReq.request.method).toBe('GET');
      personReq.flush(aPerson());

      await tick();
      const orgsReq = httpMock.expectOne(`${API_BASE_URL}/persons/1/organizations`);
      orgsReq.flush(embedded('organizations', [anOrganization()]));

      const person = await promise;
      expect(person.id).toBe(1);
      expect(person.organizations).toHaveSize(1);
      expect(person.organizations[0].name).toBe('Orion Inc.');
    });
  });

  describe('fetchPersonOrganizations', () => {
    it('interroge la sous-ressource organizations de la personne', async () => {
      const promise = service.fetchPersonOrganizations(42);

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/persons/42/organizations`);
      expect(req.request.method).toBe('GET');
      req.flush(embedded('organizations', [anOrganization({ id: 99 })]));

      const orgs = await promise;
      expect(orgs[0].id).toBe(99);
    });
  });

  describe('deleteById', () => {
    it('émet un DELETE sur la ressource', async () => {
      const promise = service.deleteById(7);

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/persons/7`);
      expect(req.request.method).toBe('DELETE');
      req.flush(null);

      await expectAsync(promise).toBeResolved();
    });
  });

  describe('save', () => {
    it("crée la personne en POST quand elle n'a pas encore d'identifiant", async () => {
      const promise = service.save(aPerson({ id: undefined }));

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/persons`);
      expect(req.request.method).toBe('POST');
      // Seuls les champs modifiables sont envoyés : ni id, ni horodatages.
      expect(req.request.body).toEqual({
        firstName: 'John',
        lastName: 'Doe',
        bio: 'Bio de John',
        phone: '+33600000000',
        email: 'jdoe@example.com',
      });
      req.flush(aPerson({ id: 123 }));

      await tick();
      httpMock
        .expectOne(`${API_BASE_URL}/persons/123/organizations`)
        .flush(embedded('organizations', []));

      const saved = await promise;
      expect(saved.id).toBe(123);
      expect(saved.organizations).toEqual([]);
    });

    it('met à jour la personne en PUT quand elle a déjà un identifiant', async () => {
      const promise = service.save(aPerson({ id: 5, firstName: 'Jane' }));

      await tick();
      const req = httpMock.expectOne(`${API_BASE_URL}/persons/5`);
      expect(req.request.method).toBe('PUT');
      expect(req.request.body.firstName).toBe('Jane');
      req.flush(aPerson({ id: 5, firstName: 'Jane' }));

      await tick();
      httpMock
        .expectOne(`${API_BASE_URL}/persons/5/organizations`)
        .flush(embedded('organizations', [anOrganization()]));

      const saved = await promise;
      expect(saved.firstName).toBe('Jane');
      expect(saved.organizations).toHaveSize(1);
    });
  });
});
