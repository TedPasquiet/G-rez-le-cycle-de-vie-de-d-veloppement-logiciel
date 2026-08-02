import { AsyncPipe, DatePipe, NgFor, NgIf } from '@angular/common';
import { Component, OnInit } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

@Component({
  selector: 'app-main-dashboard',
  standalone: true,
  imports: [RouterLink, NgFor, NgIf, AsyncPipe, DatePipe],
  templateUrl: './main-dashboard.component.html',
})
export class MainDashboardComponent implements OnInit {
  organizations: Organization[] = [];
  persons: Person[] = [];

  constructor(
    private readonly personService: PersonService,
    private readonly organizationService: OrganizationService,
  ) {}

  ngOnInit(): void {
    this.personService.fetchAll().then((persons) => (this.persons = persons));
    this.organizationService.fetchAll().then((orgs) => (this.organizations = orgs));
  }
}
