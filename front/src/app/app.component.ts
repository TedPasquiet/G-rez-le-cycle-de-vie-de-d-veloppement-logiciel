import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { HttpErrorBannerComponent } from './http-error-banner/http-error-banner.component';

@Component({
  selector: 'app-root',
  imports: [RouterOutlet, HttpErrorBannerComponent],
  templateUrl: './app.component.html',
})
export class AppComponent {
  title = 'MicroCRM';
}
