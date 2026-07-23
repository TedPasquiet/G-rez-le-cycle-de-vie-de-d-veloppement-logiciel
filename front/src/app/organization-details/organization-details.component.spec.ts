import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ActivatedRoute, Router, convertToParamMap } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';

import { OrganizationDetailsComponent } from './organization-details.component';
import { PersonService } from '../person.service';
import { OrganizationService } from '../organization.service';
import { aPerson, anOrganization } from '../test-helpers';

describe('OrganizationDetailsComponent', () => {
  let component: OrganizationDetailsComponent;
  let fixture: ComponentFixture<OrganizationDetailsComponent>;
  let personService: jasmine.SpyObj<PersonService>;
  let organizationService: jasmine.SpyObj<OrganizationService>;
  let router: Router;

  const monterAvecRoute = async (orgId: string | null) => {
    await TestBed.configureTestingModule({
      imports: [OrganizationDetailsComponent, RouterTestingModule],
      providers: [
        { provide: PersonService, useValue: personService },
        { provide: OrganizationService, useValue: organizationService },
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: convertToParamMap(orgId === null ? {} : { orgId })
            }
          }
        }
      ]
    }).compileComponents();

    router = TestBed.inject(Router);
    spyOn(router, 'navigate').and.resolveTo(true);

    fixture = TestBed.createComponent(OrganizationDetailsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
  };

  beforeEach(() => {
    personService = jasmine.createSpyObj<PersonService>('PersonService', [
      'fetchAll'
    ]);
    organizationService = jasmine.createSpyObj<OrganizationService>(
      'OrganizationService',
      ['fetchById', 'save', 'deleteById']
    );

    personService.fetchAll.and.resolveTo([]);
    organizationService.fetchById.and.resolveTo(anOrganization());
    organizationService.save.and.resolveTo(anOrganization());
    organizationService.deleteById.and.resolveTo();
  });

  it('should create', async () => {
    await monterAvecRoute('10');
    expect(component).toBeTruthy();
  });

  describe('mode création (route "new")', () => {
    it('passe en mode création sans interroger le serveur', async () => {
      await monterAvecRoute('new');

      expect(component.isNew).toBeTrue();
      expect(organizationService.fetchById).not.toHaveBeenCalled();
      expect(component.org.name).toBe('');
    });

    it('affiche le titre "New organization"', async () => {
      await monterAvecRoute('new');

      const titre = (fixture.nativeElement as HTMLElement).querySelector('h2');
      expect(titre?.textContent).toContain('New organization');
    });

    it('redirige vers la fiche créée après enregistrement', async () => {
      organizationService.save.and.resolveTo(anOrganization({ id: 55 }));

      await monterAvecRoute('new');
      component.saveOrg();
      await fixture.whenStable();

      expect(organizationService.save).toHaveBeenCalled();
      expect(router.navigate).toHaveBeenCalledWith(['organizations', 55]);
    });
  });

  describe('mode édition (route avec identifiant)', () => {
    it("charge l'organisation correspondant à l'identifiant de la route", async () => {
      organizationService.fetchById.and.resolveTo(
        anOrganization({ id: 10, name: 'Acme' })
      );

      await monterAvecRoute('10');

      expect(organizationService.fetchById).toHaveBeenCalledWith(10);
      expect(component.isNew).toBeFalse();
      expect(component.org.name).toBe('Acme');
    });

    it("affiche le nom de l'organisation dans le titre", async () => {
      organizationService.fetchById.and.resolveTo(
        anOrganization({ name: 'Acme' })
      );

      await monterAvecRoute('10');

      const titre = (fixture.nativeElement as HTMLElement).querySelector('h2');
      expect(titre?.textContent).toContain('Acme');
    });

    it('liste les membres de l\'organisation avec un lien vers leur fiche', async () => {
      organizationService.fetchById.and.resolveTo(
        anOrganization({
          persons: [
            aPerson({ id: 3, firstName: 'Jane', lastName: 'Roe', email: 'jane@example.com' })
          ]
        })
      );

      await monterAvecRoute('10');

      const lignes = (fixture.nativeElement as HTMLElement).querySelectorAll(
        'tbody tr'
      );
      expect(lignes.length).toBe(1);
      expect(lignes[0].textContent).toContain('Jane Roe');
      expect(lignes[0].textContent).toContain('jane@example.com');
      expect(lignes[0].querySelector('a')?.getAttribute('href')).toBe(
        '/persons/3'
      );
    });

    it("reste sur la fiche après enregistrement d'une organisation existante", async () => {
      await monterAvecRoute('10');
      component.saveOrg();
      await fixture.whenStable();

      expect(organizationService.save).toHaveBeenCalled();
      expect(router.navigate).not.toHaveBeenCalled();
    });

    it("supprime l'organisation puis retourne à l'accueil", async () => {
      organizationService.fetchById.and.resolveTo(anOrganization({ id: 10 }));

      await monterAvecRoute('10');
      component.deleteOrg();
      await fixture.whenStable();

      expect(organizationService.deleteById).toHaveBeenCalledWith(10);
      expect(router.navigate).toHaveBeenCalledWith(['']);
    });
  });

  it("n'appelle pas la suppression tant que l'organisation n'est pas persistée", async () => {
    await monterAvecRoute('new');

    component.deleteOrg();

    expect(organizationService.deleteById).not.toHaveBeenCalled();
    expect(router.navigate).not.toHaveBeenCalled();
  });
});
