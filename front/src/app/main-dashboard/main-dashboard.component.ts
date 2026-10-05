import { DatePipe, NgFor, NgIf } from '@angular/common';
import { Component, OnInit, inject } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';
import { LoadingState } from '../loading-state';

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

  // Un état par liste, et non un état pour l'écran : les deux requêtes partent
  // en parallèle et échouent indépendamment. Un état commun afficherait les
  // organisations comme perdues parce que les personnes le sont.
  personsState: LoadingState = 'loading';
  organizationsState: LoadingState = 'loading';

  ngOnInit(): void {
    // Les `.catch()` ci-dessous ne composent AUCUN message : c'est le travail
    // de `httpErrorInterceptor`, qui a le statut et l'URL sous la main. Ils ne
    // servent qu'à deux choses, que l'intercepteur ne peut pas faire à leur
    // place — marquer la liste concernée comme perdue, et consommer le rejet
    // pour qu'il ne finisse pas en « unhandled promise rejection ».
    this.personService
      .fetchAll()
      .then((persons) => {
        this.persons = persons;
        this.personsState = 'loaded';
      })
      .catch(() => (this.personsState = 'failed'));

    this.organizationService
      .fetchAll()
      .then((orgs) => {
        this.organizations = orgs;
        this.organizationsState = 'loaded';
      })
      .catch(() => (this.organizationsState = 'failed'));
  }
}
