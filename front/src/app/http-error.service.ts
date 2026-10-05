import { HttpErrorResponse } from '@angular/common/http';
import { Injectable, signal } from '@angular/core';

/**
 * Mémoire de la dernière requête HTTP en échec, et traduction de cet échec en
 * un message lisible à l'écran.
 *
 * Le défaut corrigé ici est celui que quatre pannes de ce projet ont eu en
 * commun — CORS bloquant, port 443 fermé, origine `http` au lieu de `https`,
 * rattachement refusé : toutes se sont manifestées par *rien du tout*. Les
 * composants enchaînaient `.then()` sans `.catch()`, donc un rejet ne changeait
 * aucun état et l'écran restait figé sur la vue d'avant. Il fallait ouvrir la
 * console du navigateur pour apprendre qu'une requête avait échoué, ce que
 * personne ne fait spontanément — des rattachements d'organisations ont
 * vraisemblablement échoué en silence pendant des jours.
 *
 * Le service ne connaît ni les composants ni le routeur : il est alimenté par
 * `httpErrorInterceptor`, un point de passage unique, et lu par
 * `HttpErrorBannerComponent`. Ce découplage est ce qui permet de couvrir aussi
 * les appels qu'on écrira demain sans se souvenir d'y ajouter quoi que ce soit.
 *
 * Les textes destinés à l'utilisateur sont en anglais : c'est la langue de
 * toute l'interface existante (« New person », « No person yet. »). Les
 * commentaires restent en français, comme partout dans le dépôt.
 */

/** Ce que la bannière a besoin de savoir pour être utile, et rien de plus. */
export interface HttpFailure {
  /** 0 quand la requête n'a jamais atteint le serveur (réseau, CORS, TLS). */
  status: number;
  method: string;
  url: string;
  title: string;
  detail: string;
}

/**
 * Traduit un code de statut en message.
 *
 * La distinction essentielle est celle entre 0 et le reste, parce qu'elle
 * désigne deux endroits différents où chercher la panne :
 *
 *   - **statut 0** : le navigateur a refusé ou n'a pas pu établir l'échange. Le
 *     serveur n'a rien vu passer, ses journaux sont muets, et regarder côté API
 *     fait perdre du temps. C'est le symptôme d'un blocage CORS, d'un port
 *     fermé ou d'un mélange http/https.
 *   - **4xx / 5xx** : le serveur a répondu. Le problème est dans la requête ou
 *     dans le traitement, et les journaux de l'API sont exploitables.
 *
 * Le 403 a son propre message, et ce n'est pas du zèle : le back renvoie 403
 * sur une origine CORS non autorisée. Un 403 ici se lit donc naturellement
 * comme « droits insuffisants » alors qu'il s'agit une fois sur deux d'une
 * `FRONT_API_BASE_URL` qui ne correspond pas aux origines déclarées. Sans ce
 * rappel, on part chercher un problème de permissions qui n'existe pas.
 */
const decrit = (status: number): Pick<HttpFailure, 'title' | 'detail'> => {
  if (status === 0) {
    return {
      title: 'Server unreachable',
      detail:
        'The request never reached the API (status 0), so the server logged nothing. ' +
        'Typical causes: the API is down, the port is closed, the origin was blocked by CORS, ' +
        'or the page is served over https while the API is called over http.',
    };
  }

  if (status === 403) {
    return {
      title: 'Request rejected (HTTP 403)',
      detail:
        'The API refused the request, and nothing was changed. On this back end a 403 is also ' +
        'the answer to a request coming from an origin that CORS does not allow: check the ' +
        'configured API base URL before looking for a permission problem.',
    };
  }

  if (status >= 500) {
    return {
      title: `Server error (HTTP ${status})`,
      detail:
        'The API received the request but failed while handling it. Any change may not have ' +
        'been applied. Retry, then check the server logs.',
    };
  }

  return {
    title: `Request rejected (HTTP ${status})`,
    detail: 'The API refused the request, and nothing was changed.',
  };
};

@Injectable({ providedIn: 'root' })
export class HttpErrorService {
  private readonly derniere = signal<HttpFailure | null>(null);

  /** Dernier échec, ou `null` si rien n'est à signaler. */
  readonly failure = this.derniere.asReadonly();

  /**
   * Enregistre un échec. La méthode HTTP est passée à part : `HttpErrorResponse`
   * porte l'URL mais pas le verbe, or « GET /persons » et « POST /persons » ne
   * racontent pas la même histoire quand on cherche ce qui a été perdu.
   */
  report(erreur: HttpErrorResponse, method: string): void {
    this.derniere.set({
      status: erreur.status,
      method,
      // `url` est nul quand la requête est annulée avant d'être construite ;
      // afficher « null » à l'écran serait pire que de l'annoncer.
      url: erreur.url ?? 'unknown URL',
      ...decrit(erreur.status),
    });
  }

  /**
   * Efface le message. Appelé par la croix de la bannière, et seulement par
   * elle : effacer automatiquement sur la première requête réussie serait un
   * piège, car le tableau de bord lance deux requêtes en parallèle et la
   * réussite de l'une effacerait l'échec de l'autre avant qu'on l'ait lu.
   */
  clear(): void {
    this.derniere.set(null);
  }
}
