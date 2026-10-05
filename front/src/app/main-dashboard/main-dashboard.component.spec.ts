import { ComponentFixture, TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';

import { MainDashboardComponent } from './main-dashboard.component';
import { PersonService } from '../person.service';
import { OrganizationService } from '../organization.service';
import { aPerson, anOrganization } from '../test-helpers';

describe('MainDashboardComponent', () => {
  let component: MainDashboardComponent;
  let fixture: ComponentFixture<MainDashboardComponent>;
  let personService: jasmine.SpyObj<PersonService>;
  let organizationService: jasmine.SpyObj<OrganizationService>;

  /** Monte le composant après avoir figé ce que renvoient les services. */
  const monter = async () => {
    fixture = TestBed.createComponent(MainDashboardComponent);
    component = fixture.componentInstance;
    fixture.detectChanges(); // déclenche ngOnInit
    await fixture.whenStable();
    fixture.detectChanges(); // rend les données chargées
  };

  beforeEach(async () => {
    personService = jasmine.createSpyObj<PersonService>('PersonService', ['fetchAll']);
    organizationService = jasmine.createSpyObj<OrganizationService>('OrganizationService', [
      'fetchAll',
    ]);
    personService.fetchAll.and.resolveTo([]);
    organizationService.fetchAll.and.resolveTo([]);

    await TestBed.configureTestingModule({
      imports: [MainDashboardComponent, RouterTestingModule],
      providers: [
        { provide: PersonService, useValue: personService },
        { provide: OrganizationService, useValue: organizationService },
      ],
    }).compileComponents();
  });

  it('should create', async () => {
    await monter();
    expect(component).toBeTruthy();
  });

  it('charge les personnes et les organisations au démarrage', async () => {
    personService.fetchAll.and.resolveTo([aPerson(), aPerson({ id: 2 })]);
    organizationService.fetchAll.and.resolveTo([anOrganization()]);

    await monter();

    expect(personService.fetchAll).toHaveBeenCalledTimes(1);
    expect(organizationService.fetchAll).toHaveBeenCalledTimes(1);
    expect(component.persons).toHaveSize(2);
    expect(component.organizations).toHaveSize(1);
  });

  it('affiche une ligne par personne avec un lien vers sa fiche', async () => {
    personService.fetchAll.and.resolveTo([
      aPerson({ id: 42, firstName: 'Jane', lastName: 'Roe', email: 'jane@example.com' }),
    ]);

    await monter();

    const html = fixture.nativeElement as HTMLElement;
    const lignes = html.querySelectorAll('table')[0].querySelectorAll('tbody tr');
    expect(lignes).toHaveSize(1);
    expect(lignes[0].textContent).toContain('Jane Roe');
    expect(lignes[0].textContent).toContain('jane@example.com');
    expect(lignes[0].querySelector('a')?.getAttribute('href')).toBe('/persons/42');
  });

  it('affiche une ligne par organisation avec un lien vers sa fiche', async () => {
    organizationService.fetchAll.and.resolveTo([anOrganization({ id: 7, name: 'Acme' })]);

    await monter();

    const html = fixture.nativeElement as HTMLElement;
    const lignes = html.querySelectorAll('table')[1].querySelectorAll('tbody tr');
    expect(lignes).toHaveSize(1);
    expect(lignes[0].textContent).toContain('Acme');
    expect(lignes[0].querySelector('a')?.getAttribute('href')).toBe('/organizations/7');
  });

  it('propose de créer une fiche quand les deux listes sont vides', async () => {
    await monter();

    const texte = (fixture.nativeElement as HTMLElement).textContent ?? '';
    expect(texte).toContain('No person yet.');
    expect(texte).toContain('No organization yet.');
  });

  describe('échec de chargement', () => {
    const texte = () => (fixture.nativeElement as HTMLElement).textContent ?? '';

    /**
     * Le défaut historique : `fetchAll()` rejetait, le `.then()` ne s'exécutait
     * pas, `persons` restait à `[]` et l'écran affichait « No person yet. ».
     * L'utilisateur lisait donc une affirmation — il n'y a aucune personne —
     * alors que rien n'avait été reçu. Ce test regarde le rendu, parce que
     * c'est là que le mensonge se produisait.
     */
    it("n'affirme pas que la liste est vide quand son chargement a échoué", async () => {
      personService.fetchAll.and.rejectWith(new Error('réseau'));

      await monter();

      expect(component.personsState).toBe('failed');
      expect(texte())
        .withContext('« vide » et « échec » doivent cesser d’être indiscernables')
        .not.toContain('No person yet.');
      expect(texte()).toContain('Persons could not be loaded.');
    });

    /**
     * Les deux listes sont chargées par deux requêtes indépendantes : l'échec
     * de l'une ne doit pas condamner l'affichage de l'autre.
     */
    it("n'étend pas l'échec d'une liste à l'autre", async () => {
      organizationService.fetchAll.and.rejectWith(new Error('réseau'));
      personService.fetchAll.and.resolveTo([aPerson({ firstName: 'Jane', lastName: 'Roe' })]);

      await monter();

      expect(component.organizationsState).toBe('failed');
      expect(component.personsState).toBe('loaded');
      expect(texte()).toContain('Organizations could not be loaded.');
      expect(texte()).not.toContain('No organization yet.');
      expect(texte()).toContain('Jane Roe');
    });
  });

  /**
   * Troisième état, distinct des deux autres : tant que la réponse n'est pas
   * revenue, on ne sait pas encore si la liste est vide.
   */
  it('annonce le chargement en cours plutôt qu’une liste vide', () => {
    personService.fetchAll.and.returnValue(new Promise(() => undefined));
    organizationService.fetchAll.and.returnValue(new Promise(() => undefined));

    fixture = TestBed.createComponent(MainDashboardComponent);
    component = fixture.componentInstance;
    fixture.detectChanges(); // ngOnInit, mais aucune promesse résolue

    const texte = (fixture.nativeElement as HTMLElement).textContent ?? '';
    expect(component.personsState).toBe('loading');
    expect(texte).toContain('Loading persons…');
    expect(texte).toContain('Loading organizations…');
    expect(texte).not.toContain('No person yet.');
  });
});
