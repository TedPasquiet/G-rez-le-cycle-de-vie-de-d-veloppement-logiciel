# Les versions sont surchargeables au build (--build-arg) mais figées par
# défaut : un tag flottant fait dépendre le contenu de l'image de la date de
# construction. Le tag est ici épinglé à JDK équivalent, sans changer de
# version — l'alignement sur le JDK 21 du pipeline est un sujet distinct.
ARG GRADLE_IMAGE=gradle:8.14.5-jdk17
ARG RUNTIME_IMAGE=alpine:3.19

# --- étape 1 : compilation du jar ---
FROM ${GRADLE_IMAGE} AS build

COPY . /src
WORKDIR /src
RUN ./gradlew build

# --- étape 2 : image d'exécution ---
FROM ${RUNTIME_IMAGE} AS back

RUN apk add --no-cache openjdk21-jre-headless \
    && adduser -D -H app

# Motif *.jar plutôt que le nom complet : le numéro de version vit dans
# back/build.gradle, et `jar.enabled = false` y garantit qu'une seule archive
# est produite. Un bump de version ne casse donc plus la construction.
COPY --from=build /src/build/libs/*.jar /app/microcrm.jar

WORKDIR /app
USER app
EXPOSE 4200

CMD ["java", "-jar", "/app/microcrm.jar"]
