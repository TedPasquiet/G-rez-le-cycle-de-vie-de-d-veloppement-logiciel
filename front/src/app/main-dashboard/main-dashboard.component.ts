import { DatePipe, NgFor, NgIf } from '@angular/common';
import { Component, OnInit, inject } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

@Component({
  selector: 'app-main-dashboard',
  imports: [RouterLink, NgFor, NgIf, DatePipe],
  templateUrl: './main-dashboard.component.html',
})
export class MainDashboardComponent implements OnInit {
  private readonly personService = inject(PersonService);
  private readonly organizationService = inject(OrganizationService);

  organizations: Organization[] = [];
  persons: Person[] = [];

  ngOnInit(): void {
    this.personService.fetchAll().then((persons) => (this.persons = persons));
    this.organizationService.fetchAll().then((orgs) => (this.organizations = orgs));
  }
}
