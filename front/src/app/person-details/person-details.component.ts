import { NgFor, NgIf } from '@angular/common';
import { Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';
import { LoadingState } from '../loading-state';

@Component({
  selector: 'app-person-details',
  imports: [NgIf, FormsModule, NgFor, RouterLink],
  templateUrl: './person-details.component.html',
})
export class PersonDetailsComponent implements OnInit {
  private readonly route = inject(ActivatedRoute);
  private readonly personService = inject(PersonService);
  private readonly organizationService = inject(OrganizationService);
  private readonly router = inject(Router);

  person: Person = {
    id: undefined as number | undefined,
    firstName: '',
    lastName: '',
    phone: '',
    email: '',
    bio: '',
    createdAt: new Date(),
    updatedAt: undefined as Date | undefined,
    organizations: [] as Organization[],
  };

  organizations: Organization[] = [];
  selectedOrganization: Organization | null = null;
  isNew: boolean = false;

  // Initialisé à 'loaded' et non à 'loading' : en création, et sur une route
  // sans paramètre, aucune requête n'est lancée. Partir de 'loading' laisserait
  // un « Loading person… » affiché indéfiniment sur une fiche vierge.
  personState: LoadingState = 'loaded';

  ngOnInit(): void {
    // Le catalogue alimente la liste déroulante de rattachement. Son échec est
    // déjà annoncé par la bannière ; on consomme le rejet pour qu'il ne parte
    // pas en « unhandled promise rejection », et la liste reste vide.
    this.organizationService
      .fetchAll()
      .then((orgs) => (this.organizations = orgs))
      .catch(() => undefined);

    const routeParams = this.route.snapshot.paramMap;
    const personIdParam = routeParams.get('personId');

    if (personIdParam === 'new') {
      this.isNew = true;
    } else if (typeof personIdParam === 'string') {
      const personId = Number.parseInt(personIdParam);
      this.personState = 'loading';
      this.personService
        .fetchById(personId)
        .then((p) => {
          this.person = p;
          this.isNew = false;
          this.personState = 'loaded';
        })
        .catch(() => (this.personState = 'failed'));
    }
  }

  savePerson() {
    this.personService
      .save({
        ...this.person,
      })
      .then((p) => {
        this.person = p;
        if (this.isNew) {
          this.router.navigate(['persons', p.id]);
        }
      })
      // Sur échec on ne navigue pas : rediriger vers la fiche d'une personne
      // qui n'a pas été créée donnerait l'illusion d'un enregistrement réussi.
      .catch(() => undefined);
  }

  deletePerson() {
    if (this.person.id === undefined) return;
    this.personService
      .deleteById(this.person.id)
      .then(() => {
        this.router.navigate(['']);
      })
      // Même raison : un retour à l'accueil après une suppression refusée
      // laisse croire que la fiche a disparu, alors qu'elle est toujours là.
      .catch(() => undefined);
  }

  // Les deux méthodes attendent la fin de l'écriture avant de recharger la
  // fiche. Sans le `await`, le rechargement partait en parallèle de la requête
  // de rattachement : l'écran réaffichait l'état d'avant, et le rattachement
  // n'apparaissait qu'au rafraîchissement suivant.
  //
  // Le `try` qui les enveloppe maintenant n'est pas décoratif : ces deux appels
  // sont ceux qui ont échoué en silence le plus longtemps sur ce projet. Le
  // message est affiché par l'intercepteur ; ici on s'interdit seulement de
  // recharger après un échec, un rechargement réussi ressemblant à s'y
  // méprendre à une opération qui a fonctionné.
  async addSelectedOrganization() {
    if (this.selectedOrganization?.id === undefined || this.person.id === undefined) return;
    try {
      await this.organizationService.addPerson(this.selectedOrganization.id, this.person.id);
    } catch {
      return;
    }
    await this.refresh();
  }

  async removeOrganization(org: Organization) {
    if (org?.id === undefined || this.person.id === undefined) return;
    try {
      await this.organizationService.removePerson(org.id, this.person.id);
    } catch {
      return;
    }
    await this.refresh();
  }

  async refresh() {
    if (this.person.id === undefined) return;
    this.personState = 'loading';
    try {
      this.person = await this.personService.fetchById(this.person.id);
      this.isNew = false;
      this.personState = 'loaded';
    } catch {
      this.personState = 'failed';
    }
  }
}
