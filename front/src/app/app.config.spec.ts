import { HttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { firstValueFrom } from 'rxjs';

import { appConfig } from './app.config';
import { HttpErrorService } from './http-error.service';

/**
 * L'intercepteur est testé pour lui-même ailleurs. Ce qui manque alors, et que
 * ce fichier couvre, c'est la question triviale dont dépend tout le mécanisme :
 * est-il réellement BRANCHÉ ?
 *
 * Sans ce test, retirer `withInterceptors([httpErrorInterceptor])` de
 * `app.config.ts` laisserait les 110 autres tests au vert tout en rendant
 * l'application entière muette sur ses pannes — soit exactement le défaut
 * d'origine, restauré sans que rien ne proteste. Le montage est ici la partie
 * fragile, pas la logique.
 */
describe('appConfig', () => {
  let http: HttpClient;
  let controleur: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      // `provideHttpClientTesting()` vient APRÈS les fournisseurs de
      // l'application : il remplace le dorsal réseau sans toucher à la chaîne
      // d'intercepteurs, qui est justement ce qu'on veut observer.
      providers: [...appConfig.providers, provideHttpClientTesting()],
    });

    http = TestBed.inject(HttpClient);
    controleur = TestBed.inject(HttpTestingController);
  });

  afterEach(() => controleur.verify());

  it("branche l'intercepteur d'erreurs sur le client HTTP de l'application", async () => {
    const promesse = firstValueFrom(http.get('/persons'));
    controleur.expectOne('/persons').error(new ProgressEvent('error'), { status: 0 });
    await expectAsync(promesse).toBeRejected();

    expect(TestBed.inject(HttpErrorService).failure()?.title)
      .withContext("un échec HTTP doit être signalé sans qu'aucun composant s'en mêle")
      .toBe('Server unreachable');
  });
});
