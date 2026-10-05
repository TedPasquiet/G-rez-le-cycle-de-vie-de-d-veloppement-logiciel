import { NgIf } from '@angular/common';
import { Component, inject } from '@angular/core';
import { HttpErrorService } from '../http-error.service';

/**
 * Bannière affichant le dernier échec HTTP.
 *
 * Elle est posée dans `app.component.html`, au-dessus du `router-outlet`, et
 * non dans chaque écran : un échec survenu juste avant une navigation resterait
 * visible, alors qu'une bannière par composant disparaîtrait avec lui — le
 * message le plus utile est justement celui de la requête qui vient de casser
 * la page qu'on quitte.
 *
 * L'état est lu par signal. Le rendu se met donc à jour quand l'intercepteur
 * écrit, sans que la bannière ait à s'abonner à quoi que ce soit ni à être
 * notifiée par le composant qui a lancé la requête.
 */
@Component({
  selector: 'app-http-error-banner',
  imports: [NgIf],
  templateUrl: './http-error-banner.component.html',
})
export class HttpErrorBannerComponent {
  private readonly journal = inject(HttpErrorService);

  readonly failure = this.journal.failure;

  dismiss(): void {
    this.journal.clear();
  }
}
