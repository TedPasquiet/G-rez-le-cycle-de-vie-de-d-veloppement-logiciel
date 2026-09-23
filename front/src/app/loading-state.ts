/**
 * État d'un chargement affiché à l'écran.
 *
 * Trois valeurs et non un booléen, parce que le défaut à corriger tient
 * exactement dans la valeur manquante : avec `chargement: boolean`, une liste
 * vide et une liste dont le chargement a échoué retombent toutes deux sur
 * « pas en cours », et l'écran affiche « No person yet. » alors que le serveur
 * est injoignable. C'est le pire des messages possibles — il est rassurant et
 * faux.
 *
 * La bannière d'erreur (`HttpErrorBannerComponent`) dit *ce qui* a échoué ;
 * cet état dit *où*, à l'endroit même où la donnée manque.
 */
export type LoadingState = 'loading' | 'loaded' | 'failed';
