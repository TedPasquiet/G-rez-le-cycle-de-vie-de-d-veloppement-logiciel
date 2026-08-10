import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { AppComponent } from './app/app.component';
import { chargeConfigurationExecution } from './app/config';

// La configuration d'exécution (URL de l'API) est chargée AVANT le démarrage de
// l'application : les services la lisent dès leur première requête, et un
// chargement concurrent laisserait passer des appels vers l'URL par défaut.
// Voir src/app/config.ts pour le détail du mécanisme.
chargeConfigurationExecution()
  .then(() => bootstrapApplication(AppComponent, appConfig))
  .catch((err) => console.error(err));
