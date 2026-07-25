import { Injectable } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { Person } from './person.service';
import { HttpClient } from '@angular/common/http';
import { API_BASE_URL } from './config';

@Injectable({ providedIn: 'root' })
export class OrganizationService {
  constructor(private client: HttpClient) {}

  async fetchById(id: number) {
    const response = await this.client.get(`${API_BASE_URL}/organizations/${id}`);
    const org = (await firstValueFrom(response)) as Organization;
    const persons = await this.fetchOrganizationPersons(org.id as number);
    org.persons = persons;
    return org;
  }

  async fetchAll() {
    const response = await this.client.get(`${API_BASE_URL}/organizations`);
    const result = (await firstValueFrom(response)) as {
      _embedded: { organizations: Organization[] };
    };
    return result._embedded.organizations;
  }

  async fetchOrganizationPersons(id: number) {
    const response = await this.client.get(`${API_BASE_URL}/organizations/${id}/persons`);
    const result = (await firstValueFrom(response)) as { _embedded: { persons: Person[] } };
    const persons = result._embedded.persons;
    return persons;
  }

  async deleteById(id: number) {
    const response = await this.client.delete(`${API_BASE_URL}/organizations/${id}`);
    await firstValueFrom(response);
    return;
  }

  async save(org: Organization) {
    let response;
    if (org.id === undefined) {
      response = await this.client.post(`${API_BASE_URL}/organizations`, {
        name: org.name,
      });
    } else {
      response = await this.client.put(`${API_BASE_URL}/organizations/${org.id}`, {
        name: org.name,
      });
    }

    org = (await firstValueFrom(response)) as Organization;

    const persons = await this.fetchOrganizationPersons(org.id as number);
    org.persons = persons;

    return org;
  }

  async addPerson(orgId: number, personId: number) {
    const response = await this.client.put(
      `${API_BASE_URL}/organizations/${orgId}/persons`,
      `${API_BASE_URL}/persons/${personId}`,
      { headers: { 'Content-Type': 'text/uri-list' } },
    );
    await firstValueFrom(response);
    return;
  }

  async removePerson(orgId: number, personId: number) {
    const response = await this.client.delete(
      `${API_BASE_URL}/persons/${personId}/organizations/${orgId}`,
    );
    await firstValueFrom(response);
    return;
  }
}

export interface Organization {
  id?: number;
  name: string;
  createdAt: Date;
  updatedAt?: Date;

  persons: Person[];
}
