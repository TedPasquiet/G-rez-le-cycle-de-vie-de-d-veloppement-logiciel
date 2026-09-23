import { HttpErrorResponse } from '@angular/common/http';
import { ComponentFixture, TestBed } from '@angular/core/testing';

import { HttpErrorBannerComponent } from './http-error-banner.component';
import { HttpErrorService } from '../http-error.service';

describe('HttpErrorBannerComponent', () => {
  let fixture: ComponentFixture<HttpErrorBannerComponent>;
  let journal: HttpErrorService;

  const texte = () => (fixture.nativeElement as HTMLElement).textContent ?? '';
  const banniere = () => (fixture.nativeElement as HTMLElement).querySelector('.notification');

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [HttpErrorBannerComponent],
    }).compileComponents();

    journal = TestBed.inject(HttpErrorService);
    fixture = TestBed.createComponent(HttpErrorBannerComponent);
    fixture.detectChanges();
  });

  it("n'occupe aucune place tant que rien n'a échoué", () => {
    expect(banniere()).toBeNull();
  });

  it("affiche le message, le statut, le verbe et l'URL de l'échec", () => {
    journal.report(
      new HttpErrorResponse({ status: 500, url: 'http://localhost:8080/persons' }),
      'GET',
    );
    fixture.detectChanges();

    expect(banniere()).not.toBeNull();
    expect(texte()).toContain('Server error (HTTP 500)');
    expect(texte()).toContain('GET http://localhost:8080/persons');
  });

  /**
   * Le point de tout l'exercice : le message doit être lisible à l'écran, pas
   * seulement présent en mémoire. On vérifie donc le RENDU et son rôle ARIA —
   * une bannière qui apparaît hors du champ de regard et que rien n'annonce
   * n'est pas plus utile qu'une trace de console.
   */
  it('annonce le message comme une alerte', () => {
    journal.report(new HttpErrorResponse({ status: 0 }), 'GET');
    fixture.detectChanges();

    expect(banniere()?.getAttribute('role')).toBe('alert');
    expect(texte()).toContain('Server unreachable');
  });

  it('disparaît quand on la ferme', () => {
    journal.report(new HttpErrorResponse({ status: 404, url: '/persons/9' }), 'GET');
    fixture.detectChanges();

    (banniere()?.querySelector('button.delete') as HTMLButtonElement).click();
    fixture.detectChanges();

    expect(banniere()).toBeNull();
    expect(journal.failure()).toBeNull();
  });
});
