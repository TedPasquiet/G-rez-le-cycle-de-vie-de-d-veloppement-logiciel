import { AsyncPipe, NgFor, NgIf } from '@angular/common';
import { Component, OnInit } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

@Component({
  selector: 'app-person-details',
  standalone: true,
  imports: [NgIf, FormsModule, AsyncPipe, NgFor, RouterLink],
  templateUrl: './person-details.component.html',
})
export class PersonDetailsComponent implements OnInit {
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

  constructor(
    private readonly route: ActivatedRoute,
    private readonly personService: PersonService,
    private readonly organizationService: OrganizationService,
    private readonly router: Router,
  ) {
    this.organizationService.fetchAll().then((orgs) => (this.organizations = orgs));
  }

  ngOnInit(): void {
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

  addSelectedOrganization() {
    if (this.selectedOrganization?.id === undefined || this.person.id === undefined) return;
    this.organizationService.addPerson(this.selectedOrganization.id, this.person.id);
    this.refresh();
  }

  removeOrganization(org: Organization) {
    if (org?.id === undefined || this.person.id === undefined) return;
    this.organizationService.removePerson(org.id, this.person.id);
    this.refresh();
  }

  refresh() {
    if (this.person.id === undefined) return;
    this.personService.fetchById(this.person.id).then((p) => {
      this.person = p;
      this.isNew = false;
    });
  }
}
