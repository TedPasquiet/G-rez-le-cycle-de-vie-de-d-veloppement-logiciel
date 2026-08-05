# Versions surchargeables au build (--build-arg), figées par défaut et alignées
# sur NODE_IMAGE du pipeline : le front doit être compilé avec le même Node que
# celui qui a servi à le tester.
ARG NODE_IMAGE=node:22-alpine
ARG RUNTIME_IMAGE=caddy:2-alpine

# --- étape 1 : build du front ---
FROM ${NODE_IMAGE} AS build

COPY . /src
WORKDIR /src
RUN npm ci \
    && npx @angular/cli build --optimization

# --- étape 2 : image d'exécution ---
FROM ${RUNTIME_IMAGE} AS front

COPY --from=build /src/dist/microcrm/browser /app/front
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 80

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]
