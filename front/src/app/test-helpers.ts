import { Organization } from './organization.service';
import { Person } from './person.service';

/**
 * Laisse la file des micro-tâches se vider.
 *
 * Indispensable avant chaque `expectOne` : les services écrivent
 * `await this.client.get(...)`, or `await` sur un Observable (qui n'est pas
 * un thenable) reporte la suite d'une micro-tâche. La souscription — et donc
 * l'émission réelle de la requête — n'a lieu qu'au tour de boucle suivant.
 * Passer par un `setTimeout` (macro-tâche) garantit que toutes les promesses
 * en attente ont été résolues avant l'assertion.
 */
export const tick = (): Promise<void> =>
  new Promise<void>((resolve) => setTimeout(resolve, 0));

/** Réponse HAL telle que la renvoie Spring Data REST pour une collection. */
export const embedded = (key: string, items: unknown[]) => ({
  _embedded: { [key]: items },
});

export const aPerson = (overrides: Partial<Person> = {}): Person => ({
  id: 1,
  firstName: 'John',
  lastName: 'Doe',
  email: 'jdoe@example.com',
  phone: '+33600000000',
  bio: 'Bio de John',
  createdAt: new Date('2024-01-01T10:00:00Z'),
  updatedAt: new Date('2024-01-02T10:00:00Z'),
  organizations: [],
  ...overrides,
});

export const anOrganization = (
  overrides: Partial<Organization> = {},
): Organization => ({
  id: 10,
  name: 'Orion Inc.',
  createdAt: new Date('2024-01-01T10:00:00Z'),
  updatedAt: new Date('2024-01-02T10:00:00Z'),
  persons: [],
  ...overrides,
});
