import { NgFor, NgIf } from '@angular/common';
import { Component, OnInit, inject } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

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

  ngOnInit(): void {
    this.organizationService.fetchAll().then((orgs) => (this.organizations = orgs));

    const routeParams = this.route.snapshot.paramMap;
    const personIdParam = routeParams.get('personId');

    if (personIdParam === 'new') {
      this.isNew = true;
    } else if (typeof personIdParam === 'string') {
      const personId = Number.parseInt(personIdParam);
      this.personService.fetchById(personId).then((p) => {
        this.person = p;
        this.isNew = false;
      });
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
      });
  }

  deletePerson() {
    if (this.person.id === undefined) return;
    this.personService.deleteById(this.person.id).then(() => {
      this.router.navigate(['']);
    });
  }

  // Les deux méthodes attendent la fin de l'écriture avant de recharger la
  // fiche. Sans le `await`, le rechargement partait en parallèle de la requête
  // de rattachement : l'écran réaffichait l'état d'avant, et le rattachement
  // n'apparaissait qu'au rafraîchissement suivant.
  async addSelectedOrganization() {
    if (this.selectedOrganization?.id === undefined || this.person.id === undefined) return;
    await this.organizationService.addPerson(this.selectedOrganization.id, this.person.id);
    await this.refresh();
  }

  async removeOrganization(org: Organization) {
    if (org?.id === undefined || this.person.id === undefined) return;
    await this.organizationService.removePerson(org.id, this.person.id);
    await this.refresh();
  }

  async refresh() {
    if (this.person.id === undefined) return;
    const rechargee = await this.personService.fetchById(this.person.id);
    this.person = rechargee;
    this.isNew = false;
  }
}
