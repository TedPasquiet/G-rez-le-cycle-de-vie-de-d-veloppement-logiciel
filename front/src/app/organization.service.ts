import { Injectable } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { Person } from './person.service';
import { HttpClient } from '@angular/common/http';
import { apiBaseUrl } from './config';

@Injectable({ providedIn: 'root' })
export class OrganizationService {
  constructor(private readonly client: HttpClient) {}

  async fetchById(id: number) {
    const response = await this.client.get(`${apiBaseUrl()}/organizations/${id}`);
    const org = (await firstValueFrom(response)) as Organization;
    const persons = await this.fetchOrganizationPersons(org.id as number);
    org.persons = persons;
    return org;
  }

  async fetchAll() {
    const response = await this.client.get(`${apiBaseUrl()}/organizations`);
    const result = (await firstValueFrom(response)) as {
      _embedded: { organizations: Organization[] };
    };
    return result._embedded.organizations;
  }

  async fetchOrganizationPersons(id: number) {
    const response = await this.client.get(`${apiBaseUrl()}/organizations/${id}/persons`);
    const result = (await firstValueFrom(response)) as { _embedded: { persons: Person[] } };
    const persons = result._embedded.persons;
    return persons;
  }

  async deleteById(id: number) {
    const response = await this.client.delete(`${apiBaseUrl()}/organizations/${id}`);
    await firstValueFrom(response);
  }

  async save(org: Organization) {
    let response;
    if (org.id === undefined) {
      response = await this.client.post(`${apiBaseUrl()}/organizations`, {
        name: org.name,
      });
    } else {
      response = await this.client.put(`${apiBaseUrl()}/organizations/${org.id}`, {
        name: org.name,
      });
    }

    org = (await firstValueFrom(response)) as Organization;

    const persons = await this.fetchOrganizationPersons(org.id as number);
    org.persons = persons;

    return org;
  }

  /**
   * Rattache une personne à une organisation.
   *
   * POST et non PUT : sur un lien d'association, Spring Data REST traite le
   * POST comme un ajout et le PUT comme un REMPLACEMENT de la liste entière.
   * En PUT, rattacher une personne évinçait silencieusement tous les autres
   * membres de l'organisation — sans erreur côté client.
   * Contrat vérifié par OrganizationRestApiTest.AssociationEndpoints (back).
   */
  async addPerson(orgId: number, personId: number) {
    const response = await this.client.post(
      `${apiBaseUrl()}/organizations/${orgId}/persons`,
      `${apiBaseUrl()}/persons/${personId}`,
      { headers: { 'Content-Type': 'text/uri-list' } },
    );
    await firstValueFrom(response);
  }

  /**
   * Détache une personne d'une organisation.
   *
   * L'URL passe par l'organisation, côté PROPRIÉTAIRE du many-to-many.
   * `Person.organizations` est le côté inverse (`mappedBy`) : il n'écrit pas
   * dans la table de jointure. Un DELETE sur
   * `/persons/{personId}/organizations/{orgId}` répond bien 204, mais
   * l'appartenance reste — le bouton semblait fonctionner sans rien faire.
   */
  async removePerson(orgId: number, personId: number) {
    const response = await this.client.delete(
      `${apiBaseUrl()}/organizations/${orgId}/persons/${personId}`,
    );
    await firstValueFrom(response);
  }
}

export interface Organization {
  id?: number;
  name: string;
  createdAt: Date;
  updatedAt?: Date;

  persons: Person[];
}
