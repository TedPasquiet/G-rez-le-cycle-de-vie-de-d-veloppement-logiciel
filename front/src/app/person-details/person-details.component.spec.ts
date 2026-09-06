import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ActivatedRoute, Router, convertToParamMap } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';

import { PersonDetailsComponent } from './person-details.component';
import { PersonService } from '../person.service';
import { OrganizationService } from '../organization.service';
import { aPerson, anOrganization } from '../test-helpers';

describe('PersonDetailsComponent', () => {
  let component: PersonDetailsComponent;
  let fixture: ComponentFixture<PersonDetailsComponent>;
  let personService: jasmine.SpyObj<PersonService>;
  let organizationService: jasmine.SpyObj<OrganizationService>;
  let router: Router;

  /**
   * Configure le TestBed pour un paramètre de route donné, puis monte le
   * composant. Le paramètre pilote tout le comportement de `ngOnInit` :
   * 'new' pour une création, un identifiant numérique pour une édition.
   */
  const monterAvecRoute = async (personId: string | null) => {
    await TestBed.configureTestingModule({
      imports: [PersonDetailsComponent, RouterTestingModule],
      providers: [
        { provide: PersonService, useValue: personService },
        { provide: OrganizationService, useValue: organizationService },
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              paramMap: convertToParamMap(personId === null ? {} : { personId }),
            },
          },
        },
      ],
    }).compileComponents();

    router = TestBed.inject(Router);
    spyOn(router, 'navigate').and.resolveTo(true);

    fixture = TestBed.createComponent(PersonDetailsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
  };

  beforeEach(() => {
    personService = jasmine.createSpyObj<PersonService>('PersonService', [
      'fetchById',
      'save',
      'deleteById',
    ]);
    organizationService = jasmine.createSpyObj<OrganizationService>('OrganizationService', [
      'fetchAll',
      'addPerson',
      'removePerson',
    ]);

    personService.fetchById.and.resolveTo(aPerson());
    personService.save.and.resolveTo(aPerson());
    personService.deleteById.and.resolveTo();
    organizationService.fetchAll.and.resolveTo([]);
    organizationService.addPerson.and.resolveTo();
    organizationService.removePerson.and.resolveTo();
  });

  it('should create', async () => {
    await monterAvecRoute('1');
    expect(component).toBeTruthy();
  });

  it("charge la liste des organisations disponibles dès l'initialisation", async () => {
    organizationService.fetchAll.and.resolveTo([anOrganization()]);

    await monterAvecRoute('new');

    expect(organizationService.fetchAll).toHaveBeenCalled();
    expect(component.organizations).toHaveSize(1);
  });

  describe('mode création (route "new")', () => {
    it('passe en mode création sans interroger le serveur', async () => {
      await monterAvecRoute('new');

      expect(component.isNew).toBeTrue();
      expect(personService.fetchById).not.toHaveBeenCalled();
      expect(component.person.firstName).toBe('');
    });

    it('affiche le titre "New person"', async () => {
      await monterAvecRoute('new');

      const titre = (fixture.nativeElement as HTMLElement).querySelector('h2');
      expect(titre?.textContent).toContain('New person');
    });

    it('redirige vers la fiche créée après enregistrement', async () => {
      personService.save.and.resolveTo(aPerson({ id: 123 }));

      await monterAvecRoute('new');
      component.savePerson();
      await fixture.whenStable();

      expect(personService.save).toHaveBeenCalled();
      expect(router.navigate).toHaveBeenCalledWith(['persons', 123]);
    });
  });

  describe('mode édition (route avec identifiant)', () => {
    it("charge la personne correspondant à l'identifiant de la route", async () => {
      personService.fetchById.and.resolveTo(aPerson({ id: 42, firstName: 'Jane' }));

      await monterAvecRoute('42');

      expect(personService.fetchById).toHaveBeenCalledWith(42);
      expect(component.isNew).toBeFalse();
      expect(component.person.firstName).toBe('Jane');
    });

    it('affiche le nom de la personne dans le titre', async () => {
      personService.fetchById.and.resolveTo(aPerson({ firstName: 'Jane', lastName: 'Roe' }));

      await monterAvecRoute('42');

      const titre = (fixture.nativeElement as HTMLElement).querySelector('h2');
      expect(titre?.textContent).toContain('Jane');
      expect(titre?.textContent).toContain('Roe');
    });

    it("reste sur la fiche après enregistrement d'une personne existante", async () => {
      await monterAvecRoute('42');
      component.savePerson();
      await fixture.whenStable();

      expect(personService.save).toHaveBeenCalled();
      expect(router.navigate).not.toHaveBeenCalled();
    });

    it("supprime la personne puis retourne à l'accueil", async () => {
      personService.fetchById.and.resolveTo(aPerson({ id: 42 }));

      await monterAvecRoute('42');
      component.deletePerson();
      await fixture.whenStable();

      expect(personService.deleteById).toHaveBeenCalledWith(42);
      expect(router.navigate).toHaveBeenCalledWith(['']);
    });
  });

  describe('garde-fous', () => {
    it("n'appelle pas la suppression tant que la personne n'est pas persistée", async () => {
      await monterAvecRoute('new');

      component.deletePerson();

      expect(personService.deleteById).not.toHaveBeenCalled();
      expect(router.navigate).not.toHaveBeenCalled();
    });

    it("n'ajoute rien tant qu'aucune organisation n'est sélectionnée", async () => {
      personService.fetchById.and.resolveTo(aPerson({ id: 42 }));
      await monterAvecRoute('42');

      component.selectedOrganization = null;
      component.addSelectedOrganization();

      expect(organizationService.addPerson).not.toHaveBeenCalled();
    });

    it("n'ajoute rien tant que la personne n'est pas persistée", async () => {
      await monterAvecRoute('new');

      component.selectedOrganization = anOrganization({ id: 10 });
      component.addSelectedOrganization();

      expect(organizationService.addPerson).not.toHaveBeenCalled();
    });

    it("ne retire rien si l'organisation n'a pas d'identifiant", async () => {
      personService.fetchById.and.resolveTo(aPerson({ id: 42 }));
      await monterAvecRoute('42');

      component.removeOrganization(anOrganization({ id: undefined }));

      expect(organizationService.removePerson).not.toHaveBeenCalled();
    });
  });

  describe('gestion des organisations rattachées', () => {
    /**
     * Rend une promesse dont on choisit le moment de résolution.
     *
     * Sans ce contrôle, un espion `resolveTo()` se résout immédiatement et
     * l'ordre des appels devient indiscernable : le test passe aussi bien que
     * l'écriture soit attendue ou non. C'est précisément ce qui masquait le
     * rechargement lancé en parallèle de la requête de rattachement.
     */
    const promesseSuspendue = () => {
      let resoudre!: () => void;
      const promesse = new Promise<void>((r) => (resoudre = r));
      return { promesse, resoudre };
    };

    beforeEach(() => {
      personService.fetchById.and.resolveTo(aPerson({ id: 42 }));
    });

    it("rattache l'organisation sélectionnée à la personne courante", async () => {
      await monterAvecRoute('42');
      personService.fetchById.calls.reset();

      component.selectedOrganization = anOrganization({ id: 10 });
      await component.addSelectedOrganization();

      expect(organizationService.addPerson).toHaveBeenCalledWith(10, 42);
      // La fiche est rechargée pour refléter le nouveau rattachement.
      expect(personService.fetchById).toHaveBeenCalledWith(42);
    });

    it("ne recharge la fiche qu'une fois le rattachement terminé", async () => {
      const { promesse, resoudre } = promesseSuspendue();
      organizationService.addPerson.and.returnValue(promesse);

      await monterAvecRoute('42');
      personService.fetchById.calls.reset();

      component.selectedOrganization = anOrganization({ id: 10 });
      const enCours = component.addSelectedOrganization();
      await Promise.resolve();

      expect(personService.fetchById)
        .withContext("la fiche ne doit pas être relue pendant l'écriture")
        .not.toHaveBeenCalled();

      resoudre();
      await enCours;

      expect(personService.fetchById).toHaveBeenCalledWith(42);
    });

    it('détache une organisation de la personne courante', async () => {
      await monterAvecRoute('42');
      personService.fetchById.calls.reset();

      await component.removeOrganization(anOrganization({ id: 10 }));

      expect(organizationService.removePerson).toHaveBeenCalledWith(10, 42);
      expect(personService.fetchById).toHaveBeenCalledWith(42);
    });

    it('ne recharge la fiche que le détachement terminé', async () => {
      const { promesse, resoudre } = promesseSuspendue();
      organizationService.removePerson.and.returnValue(promesse);

      await monterAvecRoute('42');
      personService.fetchById.calls.reset();

      const enCours = component.removeOrganization(anOrganization({ id: 10 }));
      await Promise.resolve();

      expect(personService.fetchById).not.toHaveBeenCalled();

      resoudre();
      await enCours;

      expect(personService.fetchById).toHaveBeenCalledWith(42);
    });

    it('remplace la fiche affichée par la version rechargée', async () => {
      // Le rechargement doit servir à quelque chose : la personne affichée
      // après un rattachement est bien celle que le serveur vient de renvoyer,
      // pas l'ancienne copie locale.
      await monterAvecRoute('42');
      personService.fetchById.and.resolveTo(
        aPerson({ id: 42, organizations: [anOrganization({ id: 10 })] }),
      );

      component.selectedOrganization = anOrganization({ id: 10 });
      await component.addSelectedOrganization();

      expect(component.person.organizations).toHaveSize(1);
      expect(component.isNew).toBeFalse();
    });
  });
});
