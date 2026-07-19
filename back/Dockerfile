# --- étape 1 : compilation du jar ---
FROM gradle:jdk17 AS build

COPY . /src
WORKDIR /src
RUN ./gradlew build

# --- étape 2 : image d'exécution ---
FROM alpine:3.19 AS back

RUN apk add --no-cache openjdk21-jre-headless \
    && adduser -D -H app

COPY --from=build /src/build/libs/microcrm-0.0.1-SNAPSHOT.jar /app/microcrm.jar

WORKDIR /app
USER app
EXPOSE 4200

CMD ["java", "-jar", "/app/microcrm.jar"]
