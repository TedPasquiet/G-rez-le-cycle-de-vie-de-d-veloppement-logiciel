# Versions surchargeables au build (--build-arg), figées par défaut et alignées
# sur NODE_IMAGE du pipeline : le front doit être compilé avec le même Node que
# celui qui a servi à le tester.
ARG NODE_IMAGE=node:22-alpine
# Les deux références à Caddy (le tag de l'image builder et la version passée à
# `xcaddy build`) doivent porter la même version.
ARG CADDY_BUILDER_IMAGE=caddy:2.11.4-builder-alpine
# Même Alpine que l'image d'exécution du back.
ARG RUNTIME_IMAGE=alpine:3.24

# --- étape 1 : build du front ---
FROM ${NODE_IMAGE} AS build

COPY . /src
WORKDIR /src
RUN npm ci \
    && npx @angular/cli build --optimization

# --- étape 2 : recompilation de Caddy ---
# Le binaire de l'image officielle est compilé avec Go 1.26.3 et des modules
# (golang.org/x/*, gRPC) antérieurs à leurs correctifs : 17 CVE HIGH que ni un
# changement de tag ni `apk upgrade` n'atteignent, puisqu'elles vivent DANS le
# binaire. On le recompile — même version de Caddy — avec le Go de l'image
# builder (1.26.8) et ces modules remontés à leur première version corrigée.
# Chaque `--replace` est à retirer dès qu'une version de Caddy l'embarque.
#
# La capability de fichier `cap_net_bind_service=ep` est posée ICI, comme le
# fait l'image officielle, et pas dans l'image finale : un `setcap` après le
# COPY recopierait le binaire entier dans une couche de plus. Les manifestes
# Kubernetes en dépendent (front-deployment.yaml rend NET_BIND_SERVICE).
FROM ${CADDY_BUILDER_IMAGE} AS caddy
RUN xcaddy build v2.11.4 --output /usr/bin/caddy \
    --replace golang.org/x/crypto=golang.org/x/crypto@v0.55.0 \
    --replace golang.org/x/net=golang.org/x/net@v0.56.0 \
    --replace golang.org/x/text=golang.org/x/text@v0.39.0 \
    --replace google.golang.org/grpc=google.golang.org/grpc@v1.83.2 \
    && apk add --no-cache libcap-setcap \
    && setcap cap_net_bind_service=+ep /usr/bin/caddy

# --- étape 3 : image d'exécution ---
# Alpine nue plutôt que l'image Caddy officielle : copier un binaire par-dessus
# le sien laisse l'original dans la couche du dessous, et l'image passait de
# 97 à 158 Mo. On reprend donc ce que l'image officielle prépare (caddy-docker,
# variante alpine) : certificats racine, table MIME, répertoires XDG. Sauf
# `curl`, dont rien ne se sert dans ce conteneur et qui portait à lui seul
# 20 des CVE relevées.
#
# `apk upgrade` d'abord : l'image Alpine officielle n'est reconstruite qu'à
# chaque version mineure, et les correctifs publiés entre-temps n'y sont pas.
FROM ${RUNTIME_IMAGE} AS front
RUN apk upgrade --no-cache \
    && apk add --no-cache ca-certificates mailcap \
    && adduser -D -H -u 1000 app \
    && mkdir -p /config/caddy /data/caddy /etc/caddy \
    && chown -R app:app /data /config

ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY --from=build /src/dist/microcrm/browser /app/front
COPY Caddyfile /etc/caddy/Caddyfile

USER app

EXPOSE 80

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]
