# Tableau de bord Kibana — objets sauvegardés

`MONITORING.md` §7 listait l'absence de tableau de bord versionné comme le
principal reste du lot ELK. Ce répertoire le comble.

**Le livrable n'est pas un écran dans Kibana, c'est `microcrm.ndjson`.** Un
tableau de bord construit à la souris vit dans l'index `.kibana` d'un pod ; il
disparaît avec le PVC, avec le namespace, avec le `minikube delete`. Le fichier
versionné ici est la seule forme du tableau de bord qui survive à son instance.

## Importer

```shell
kubectl -n logging port-forward svc/kibana 5601:5601

curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
  -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/microcrm.ndjson
```

La réponse doit porter `"success":true` et `"successCount":8`. Un `successCount`
inférieur signale un objet rejeté, pas un import partiel acceptable.

## Réexporter après modification

Modifier le tableau de bord dans Kibana ne modifie pas ce dépôt. Toute retouche
faite à la souris doit être réexportée, sinon elle est perdue au prochain
`minikube delete` — c'est exactement le problème que ce répertoire résout.

```shell
curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_export' \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"objects":[{"type":"dashboard","id":"microcrm-dashboard"}],
       "includeReferencesDeep":true}' \
  -o k8s/elk/dashboards/microcrm.ndjson
```

⚠️ `includeReferencesDeep` n'est pas une option de confort. Sans lui, l'export
ne contient que le tableau de bord : la vue de données `microcrm-logs*` reste
derrière, et la réimportation produit des panneaux vides derrière un message
d'erreur qui ne nomme pas la cause.

## Contenu — 8 objets

| Objet                    | Type            | Rôle                                    |
| ------------------------ | --------------- | --------------------------------------- |
| `microcrm-logs`          | `index-pattern` | vue de données `microcrm-logs*`         |
| `microcrm-volume`        | `lens`          | volume par conteneur                    |
| `microcrm-latence`       | `lens`          | percentiles de latence Caddy            |
| `microcrm-erreurs-back`  | `lens`          | niveaux WARN / ERROR du back            |
| `microcrm-erreurs-http`  | `lens`          | comptage des réponses HTTP >= 400       |
| `microcrm-statuts-http`  | `lens`          | répartition des codes de réponse        |
| `microcrm-derniers-logs` | `search`        | flux brut des événements récents        |
| `microcrm-dashboard`     | `dashboard`     | assemblage, fenêtre `now-24h` restaurée |

## Ce que chaque écran ne dit pas

Les descriptions sont portées par les objets eux-mêmes — elles s'affichent sous
l'icône ⓘ de chaque panneau, donc devant celui qui lit le tableau de bord et non
seulement devant celui qui lit ce fichier. Les limites qui changent une
conclusion :

**La latence est celle du front, jamais celle de l'API.** `caddy.duration` est
le temps de service du serveur web qui sert l'application Angular. Le journal
d'accès de Caddy ne voit passer que les fichiers statiques : les appels au back
partent du navigateur vers le service du back et ne traversent jamais le front.
Un p99 à 2 ms ne dit donc rien de la santé de l'API — il dit que Caddy sert vite
des fichiers. Mesurer la latence applicative demanderait une instrumentation du
back, qui n'existe pas.

**L'écran des erreurs HTTP est vide par construction.** Le front sert une SPA
avec `try_files … /index.html` : tout chemin inconnu renvoie 200 avec la page,
et c'est Angular qui décide ensuite qu'il n'y a rien à cette adresse. Un 404 ne
peut donc pas apparaître dans les logs de Caddy. Le zéro affiché est le
comportement attendu du routage, pas une preuve d'absence d'erreur — d'où le
titre du panneau, qui le dit plutôt que de laisser conclure. Les erreurs
observables sont celles du back, panneau voisin.

**Le volume compte des lignes de log, pas des requêtes.** Une requête peut
n'en produire aucune, un démarrage en produit cinquante.

**Les erreurs du back ne couvrent que les lignes encodées en ECS.** La bannière
ASCII de Spring Boot et les quelques lignes émises avant l'initialisation de
Logback n'ont pas de champ `log.level` : elles sont invisibles à ce panneau. Sur
355 documents, 54 portent un `log.level`.

**Le front n'a pas de `log.level`, et son `message` reste le JSON brut.** Son
journal est décodé sous le préfixe `caddy` (`MONITORING.md` §4), précisément
pour ne pas entrer en collision avec l'espace ECS : ses champs exploitables sont
donc `caddy.status`, `caddy.duration`, `caddy.request.uri`, jamais `log.level`.
La colonne `message` de la table affiche la ligne d'origine, non réécrite — un
tiret dans la colonne `log.level` signale une ligne du front, pas une anomalie.

## Deux pièges de construction, réglés ici

**`caddy.duration` est en secondes.** Affiché tel quel, le p50 vaut `0.00043` —
un axe illisible. La conversion n'est pas faite dans les visualisations mais
**une seule fois, dans le `fieldFormatMap` de la vue de données** : le champ est
déclaré `inputFormat: seconds` / `outputFormat: asMilliseconds`. Tout panneau
qui touche ce champ hérite de l'unité, y compris ceux qui n'existent pas encore.
C'est aussi pourquoi la vue de données doit impérativement faire partie de
l'export : sans elle, l'unité est perdue en même temps que le reste.

**`log.level` est une clé plate qui cohabite avec un objet `log` imbriqué.**
Le `_source` d'un document du back contient à la fois `"log.level": "INFO"` et
`"log": {"file": {"path": …}}`. Elasticsearch les fusionne au mapping et Kibana
les résout par l'API `fields`, donc filtrage et affichage fonctionnent — vérifié
plutôt que supposé : `log.level: *` renvoie 54 documents dans Kibana, soit
exactement les 52 `INFO` + 2 `WARN` comptés par une agrégation `terms` sur
Elasticsearch. Le pipeline d'ingestion évoqué en `MONITORING.md` §7 reste
souhaitable pour la propreté, mais il n'est pas nécessaire à ces écrans.

## Limites de l'ensemble

La fenêtre par défaut est `now-24h` et elle est **restaurée à l'ouverture**
(`timeRestore`), pour que le tableau de bord montre des données dès l'import
plutôt qu'un écran vide sur une plage de 15 minutes.

Aucune alerte : ces écrans se regardent, ils ne préviennent pas. Aucune
rétention non plus — sans ILM, l'historique s'arrête là où le PVC se remplit.

## Le second tableau de bord : `dora.ndjson`

13 objets, index `microcrm-dora`, alimenté par `scripts/ci/collect_dora.py`.

```shell
kubectl -n logging port-forward svc/kibana 5601:5601
curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_import?overwrite=true' \
  -H 'kbn-xsrf: true' --form file=@k8s/elk/dashboards/dora.ndjson
```

### ⚠️ Ce que ces écrans affichent, et qu'il faut lire avant de conclure

**La chaîne déploie depuis le 2026-09-22**, après sept échecs et deux mois de
quota épuisé. Les quatre indicateurs ont donc une valeur, et celle du taux
d'échec n'est pas flatteuse — ce qui est le sujet : ces chiffres disent ce que
le projet a fait, pas ce qu'on voudrait montrer.

Mesuré le 2026-09-23 sur 30 jours :

| Indicateur                   | Valeur        | Ce que ça veut dire                                                               |
| ---------------------------- | ------------- | --------------------------------------------------------------------------------- |
| Fréquence de déploiement     | `0,1667`/jour | 5 déploiements réussis, tous sur deux journées consécutives                       |
| Délai de mise en production  | `1,38 h`      | médiane sur 5 observations ; le déclenchement est manuel, l'attente du clic y est |
| Temps de rétablissement      | `2,14 h`      | médiane sur 2 observations seulement                                              |
| Taux d'échec des changements | `66,67 %`     | 6 échecs sur 9 tentatives, dont 2 comptés comme annulés par un rollback           |

⚠️ **Deux titres de ce tableau de bord datent d'avant le déblocage** et doivent
être refaits à la prochaine régénération : celui du tableau lui-même
(« MicroCRM — métriques DORA (aucun déploiement réussi) ») et celui de la
recherche sauvegardée « Les sept tentatives de déploiement, une par ligne ».
Ils se corrigent **dans Kibana, puis par export** — voir la mise en garde de la
section suivante ; les modifier à la main dans le NDJSON casserait l'import.

⚠️ **Le comptage des rollbacks est volontairement pessimiste.** Un déploiement
réussi puis annulé compte comme un échec, et le rattachement du rollback au
déploiement est purement chronologique : le rollback du 2026-09-23 à 13:01:30 a
échoué sur un timeout, n'a donc rien annulé, et compte quand même comme une
annulation. C'est assumé et non corrigé ; le détail est dans `MONITORING.md`
§9.3.

### Pourquoi deux indicateurs ne sont pas des métriques

`lead_time_for_changes` et `mean_time_to_restore` sont rendus par des panneaux
de **texte**, pas par des panneaux de métrique. Ce n'est pas un détour
esthétique : Kibana affiche `0` ou `-` pour une métrique vide, et un délai de
mise en production de zéro heure se lit comme la performance parfaite — là où
il n'y a parfois simplement pas eu de mise en production. Ces deux indicateurs
ont aujourd'hui une valeur, mais le choix reste le bon : il suffit d'une fenêtre
sans déploiement pour que le cas revienne.

Confondre « zéro mesuré » et « pas de donnée » est le pire défaut qu'un tableau
de bord puisse avoir, parce que le second se lit comme un exploit. Le panneau
« Comment lire ce tableau de bord » est là pour la même raison, et le titre du
tableau de bord porte la réserve.

### Régénérer après modification

Comme pour `microcrm.ndjson` : modifier dans Kibana, puis exporter — **jamais
éditer le NDJSON à la main**, un objet sans `typeMigrationVersion` fait échouer
l'import sur `Cannot read properties of undefined (reading 'layers')`.

```shell
curl -s -X POST 'http://127.0.0.1:5601/api/saved_objects/_export' \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"objects":[{"type":"dashboard","id":"dora-dashboard"}],"includeReferencesDeep":true}' \
  > k8s/elk/dashboards/dora.ndjson
```

Vérifié le 2026-08-18, objets préalablement supprimés pour que le test soit
froid : `{"success": true, "successCount": 13}`, aucune erreur. Et les quatre
valeurs lues dans l'index correspondaient exactement à ce que rendait alors le
collecteur, `null` compris. Les objets n'ont pas été réexportés depuis le
déblocage du 2026-09-22 : les panneaux, eux, lisent l'index et suivent donc les
nouvelles valeurs — ce sont les deux titres signalés plus haut qui ne suivent
pas.
