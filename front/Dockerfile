# --- étape 1 : build du front ---
FROM node:22-alpine AS build

COPY . /src
WORKDIR /src
RUN npm ci \
    && npx @angular/cli build --optimization

# --- étape 2 : image d'exécution ---
FROM caddy:2-alpine AS front

COPY --from=build /src/dist/microcrm/browser /app/front
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 80

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]
