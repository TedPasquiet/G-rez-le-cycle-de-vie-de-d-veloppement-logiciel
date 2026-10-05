import { TestBed } from '@angular/core/testing';
import { AppComponent } from './app.component';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';

describe('AppComponent', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AppComponent],
      providers: [provideHttpClient(withInterceptorsFromDi()), provideHttpClientTesting()],
    }).compileComponents();
  });

  it('should create the app', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const app = fixture.componentInstance;
    expect(app).toBeTruthy();
  });

  it(`should have the 'MicroCRM' title`, () => {
    const fixture = TestBed.createComponent(AppComponent);
    const app = fixture.componentInstance;
    expect(app.title).toEqual('MicroCRM');
  });

  it('should render title', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('h1')?.textContent).toContain('MicroCRM');
  });

  /**
   * La bannière ne sert à rien si elle n'est pas montée. Elle est placée dans
   * la coquille, au-dessus du `router-outlet`, pour survivre aux navigations :
   * un échec survenu juste avant un changement d'écran reste lisible.
   */
  it("monte la bannière d'erreur au-dessus du router-outlet", () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    const compiled = fixture.nativeElement as HTMLElement;

    const banniere = compiled.querySelector('app-http-error-banner');
    expect(banniere).not.toBeNull();
    expect(banniere?.nextElementSibling?.tagName.toLowerCase()).toBe('router-outlet');
  });
});
