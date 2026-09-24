import { HttpErrorResponse, HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { catchError, throwError } from 'rxjs';
import { HttpErrorService } from './http-error.service';

/**
 * Signale à l'utilisateur toute requête HTTP en échec.
 *
 * Un intercepteur plutôt qu'un `.catch()` par appel : les quatre pannes qui ont
 * motivé ce code portaient sur quatre appels différents, et un mécanisme qu'il
 * faut penser à brancher à chaque nouvel appel finit toujours par être oublié
 * précisément là où il manquera. Branché une fois dans `app.config.ts`, celui-ci
 * couvre les appels existants **et** ceux qu'on écrira ensuite.
 *
 * Deux précautions qui ont chacune leur raison d'être :
 *
 *   1. **L'erreur est relancée**, jamais absorbée. Un intercepteur qui rendrait
 *      un flux vide transformerait l'échec en succès silencieux côté appelant —
 *      exactement le défaut qu'on corrige, déplacé d'un cran. Les composants
 *      doivent continuer à voir le rejet pour distinguer « liste vide » de
 *      « chargement échoué ».
 *   2. **Seules les `HttpErrorResponse` sont signalées.** Une erreur levée par
 *      un autre intercepteur, ou par un opérateur en aval, n'a ni statut ni URL :
 *      la présenter comme une panne réseau induirait en erreur. On la laisse
 *      passer telle quelle.
 */
export const httpErrorInterceptor: HttpInterceptorFn = (requete, suivant) => {
  // `inject()` est appelé dans le corps de l'intercepteur, et surtout PAS dans
  // le `catchError` : Angular n'expose le contexte d'injection que pendant
  // l'exécution synchrone de la fonction. Le rappel d'erreur, lui, s'exécute
  // bien plus tard, une fois la réponse revenue — un `inject()` à cet
  // endroit-là lève NG0203, et seulement sur les requêtes qui échouent, donc
  // jamais pendant le développement au moment où tout fonctionne.
  const journal = inject(HttpErrorService);

  return suivant(requete).pipe(
    catchError((erreur: unknown) => {
      if (erreur instanceof HttpErrorResponse) {
        journal.report(erreur, requete.method);
      }
      return throwError(() => erreur);
    }),
  );
};
