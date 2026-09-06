# Les versions sont surchargeables au build (--build-arg) mais figées par
# défaut, et alignées sur celles du pipeline (.gitlab-ci.yml) : compiler avec un
# JDK différent de celui qui exécute les tests en CI, c'est livrer un artefact
# que personne n'a validé.
ARG GRADLE_IMAGE=gradle:8.14.5-jdk21
ARG RUNTIME_IMAGE=alpine:3.19

# --- étape 1 : compilation du jar ---
FROM ${GRADLE_IMAGE} AS build

COPY . /src
WORKDIR /src
RUN ./gradlew build

# --- étape 2 : image d'exécution ---
FROM ${RUNTIME_IMAGE} AS back

# Même version majeure que le JDK de compilation.
RUN apk add --no-cache openjdk21-jre-headless \
    && adduser -D -H app

# Motif *.jar plutôt que le nom complet : le numéro de version vit dans
# back/build.gradle, et `jar.enabled = false` y garantit qu'une seule archive
# est produite. Un bump de version ne casse donc plus la construction.
COPY --from=build /src/build/libs/*.jar /app/microcrm.jar

WORKDIR /app
USER app

# Port réellement écouté par Spring Boot.
EXPOSE 8080

CMD ["java", "-jar", "/app/microcrm.jar"]
