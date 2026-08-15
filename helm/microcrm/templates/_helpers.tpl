{{/*
⚠️ Ce chart ne définit VOLONTAIREMENT aucun helper « fullname », et aucun objet
n'est préfixé par le nom de la release. Les objets s'appellent littéralement
`back`, `front`, `microcrm-config` et `microcrm`.

C'est le contraire du réflexe Helm, et c'est le point le plus contre-intuitif du
chart. Raison : scripts/deploy/deploy.sh exécute
`kubectl set image deployment/back back=<image>` et `rollback.sh` cible les
mêmes noms via $APP_BACK_NAME / $APP_FRONT_NAME. Un préfixe `{{ .Release.Name }}-`
renommerait les Deployments en `<release>-back`, et le déploiement échouerait au
premier `set image`, tardivement et avec un message peu parlant
(« Deployment 'back' introuvable »).

C'est exactement pour cette raison que les overlays Kustomize se passent eux
aussi de `namePrefix` — voir k8s/overlays/staging/kustomization.yaml et
K8S.md §7. L'isolation entre environnements est assurée par le namespace, qui
les rend étanches ; un préfixe n'ajouterait rien.

Corollaire assumé : deux releases de ce chart dans le MÊME namespace
entreraient en collision. C'est sans objet ici, un namespace valant un
environnement.
*/}}

{{/*
Labels d'identité communs à toutes les ressources, ceux que Kustomize pose
depuis `labels:` dans la base et dans chaque overlay. Les labels propres à une
ressource (`name`, `component`) restent écrits dans chaque template, où ils se
lisent à côté de l'objet qu'ils décrivent.

`managed-by` vaut `Helm`, avec une majuscule, et ce n'est pas une coquetterie :
Helm RÉÉCRIT ce label sur tout objet qu'il applique, quelle que soit la valeur
rendue ici. Vérifié en installant le chart dans un namespace jetable — la
ConfigMap déployée portait `app.kubernetes.io/managed-by: Helm` ainsi que les
annotations `meta.helm.sh/release-name` et `meta.helm.sh/release-namespace`,
que Helm pose lui aussi. Écrire `helm` en minuscules donnerait un rendu qui ne
correspond pas à l'objet réellement déployé.

C'est la seule différence attendue avec le rendu Kustomize, qui porte
`managed-by: kustomize`.

`instance` et `environment` ne sont émis que si un environnement est fourni :
sans `-f`, le rendu est celui de la base, qui n'appartient à aucun
environnement.
*/}}
{{- define "microcrm.labels" -}}
app.kubernetes.io/part-of: microcrm
app.kubernetes.io/managed-by: Helm
{{- with .Values.environment }}
app.kubernetes.io/instance: microcrm-{{ . }}
app.kubernetes.io/environment: {{ . }}
{{- end }}
{{- end -}}

{{/*
Référence d'image d'un composant. Le nom passé en argument est aussi celui du
conteneur et du Deployment : la CI construit `$CI_REGISTRY_IMAGE/back:<sha>`
(.gitlab-ci.yml), la même composition qu'ici.
*/}}
{{- define "microcrm.image" -}}
{{ .root.Values.image.repository }}/{{ .name }}:{{ .root.Values.image.tag }}
{{- end -}}
