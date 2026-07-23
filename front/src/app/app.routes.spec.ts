import { routes } from './app.routes';
import { MainDashboardComponent } from './main-dashboard/main-dashboard.component';
import { PersonDetailsComponent } from './person-details/person-details.component';
import { OrganizationDetailsComponent } from './organization-details/organization-details.component';

describe('app.routes', () => {
  it('sert le tableau de bord à la racine', () => {
    expect(routes[0]).toEqual({ path: '', component: MainDashboardComponent });
  });

  it('expose la fiche personne sur /persons/:personId', () => {
    const route = routes.find((r) => r.path === 'persons/:personId');
    expect(route?.component).toBe(PersonDetailsComponent);
  });

  it('expose la fiche organisation sur /organizations/:orgId', () => {
    const route = routes.find((r) => r.path === 'organizations/:orgId');
    expect(route?.component).toBe(OrganizationDetailsComponent);
  });

  it('redirige toute URL inconnue vers le tableau de bord', () => {
    // La route joker doit rester en dernier, sinon elle capterait tout.
    const derniere = routes[routes.length - 1];
    expect(derniere.path).toBe('**');
    expect(derniere.redirectTo).toBe('');
  });
});
