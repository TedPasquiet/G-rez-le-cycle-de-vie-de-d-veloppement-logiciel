import { ApplicationConfig } from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';

import { routes } from './app.routes';
import { httpErrorInterceptor } from './http-error.interceptor';

export const appConfig: ApplicationConfig = {
  providers: [
    // `httpErrorInterceptor` est le seul endroit où un échec HTTP devient
    // visible à l'écran. Le brancher ici, et non appel par appel, est ce qui
    // garantit qu'un appel ajouté plus tard sera couvert sans qu'on y pense.
    // Voir src/app/http-error.interceptor.ts pour le raisonnement.
    provideHttpClient(withFetch(), withInterceptors([httpErrorInterceptor])),
    provideRouter(routes),
  ],
};
