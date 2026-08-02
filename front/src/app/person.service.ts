import { Injectable } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { Organization } from './organization.service';
import { HttpClient } from '@angular/common/http';
import { API_BASE_URL } from './config';

@Injectable({ providedIn: 'root' })
export class PersonService {
  constructor(private readonly client: HttpClient) {}

  async fetchById(id: number) {
    const response = await this.client.get(`${API_BASE_URL}/persons/${id}`);
    const person = (await firstValueFrom(response)) as Person;
    const organizations = await this.fetchPersonOrganizations(person.id as number);
    person.organizations = organizations;
    return person;
  }

  async fetchAll() {
    const response = await this.client.get(`${API_BASE_URL}/persons`);
    const result = (await firstValueFrom(response)) as { _embedded: { persons: Person[] } };
    const persons = result._embedded.persons;
    return persons;
  }

  async fetchPersonOrganizations(id: number) {
    const response = await this.client.get(`${API_BASE_URL}/persons/${id}/organizations`);
    const result = (await firstValueFrom(response)) as {
      _embedded: { organizations: Organization[] };
    };
    const organizations = result._embedded.organizations;
    return organizations;
  }

  async deleteById(id: number) {
    const response = await this.client.delete(`${API_BASE_URL}/persons/${id}`);
    await firstValueFrom(response);
  }

  async save(person: Person) {
    let response;
    if (person.id === undefined) {
      response = await this.client.post(`${API_BASE_URL}/persons`, {
        firstName: person.firstName,
        lastName: person.lastName,
        bio: person.bio,
        phone: person.phone,
        email: person.email,
      });
    } else {
      response = await this.client.put(`${API_BASE_URL}/persons/${person.id}`, {
        firstName: person.firstName,
        lastName: person.lastName,
        bio: person.bio,
        phone: person.phone,
        email: person.email,
      });
    }

    person = (await firstValueFrom(response)) as Person;

    const organizations = await this.fetchPersonOrganizations(person.id as number);
    person.organizations = organizations;

    return person;
  }
}

export interface Person {
  id?: number;
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  bio: string;
  createdAt: Date;
  updatedAt?: Date;
  organizations: Organization[];
}
