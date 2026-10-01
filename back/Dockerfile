# Les versions sont surchargeables au build (--build-arg) mais figées par
# défaut, et alignées sur celles du pipeline (.gitlab-ci.yml) : compiler avec un
# JDK différent de celui qui exécute les tests en CI, c'est livrer un artefact
# que personne n'a validé.
ARG GRADLE_IMAGE=gradle:8.14.5-jdk21
ARG RUNTIME_IMAGE=alpine:3.24

# Agent Java OpenTelemetry (tracing distribué). La version ET son empreinte
# sont épinglées ensemble : surcharger l'une sans l'autre fait échouer le build
# au `sha256sum -c`, et c'est voulu — une montée de version se fait en changeant
# les DEUX lignes, empreinte relevée sur le `.sha256` publié à côté du jar dans
# Maven Central (identique à celle de l'asset de la release GitHub).
#
# ⚠️ Trivy voit ce jar comme UN SEUL paquet (io.opentelemetry.javaagent:
# opentelemetry-javaagent) : l'agent embarque ses dépendances renommées
# (OkHttp, Kotlin, protobuf...) sans leurs pom.properties, elles sont donc
# invisibles au scan d'image. Un « 0 vulnérabilité » sur ce jar n'est pas un
# certificat. Pour le vérifier à la montée de version, scanner le SBOM publié
# avec la release (opentelemetry-java-instrumentation-SBOM.zip) :
# `trivy sbom opentelemetry-javaagent.spdx.json` — 93 paquets, 0 HIGH/CRITICAL
# pour la 2.31.1 au 2026-09-29.
ARG OTEL_JAVAAGENT_VERSION=2.31.1
ARG OTEL_JAVAAGENT_SHA256=bbf83c151b6400709e2f225bdd07a04f839d9d13b8b93464241333fd25d3e3ba

# --- étape 1 : compilation du jar ---
FROM ${GRADLE_IMAGE} AS build

COPY . /src
WORKDIR /src
RUN ./gradlew build

# --- étape 2 : récupération de l'agent OpenTelemetry ---
#
# Une étape à part plutôt qu'un `ADD --checksum=` : ce drapeau n'existe qu'avec
# BuildKit (syntaxe Dockerfile ≥ 1.6), alors que le builder historique de
# Docker ne le connaît pas et refuse le Dockerfile entier. Ici, `wget` et
# `sha256sum` sont ceux de BusyBox, déjà présents dans Alpine : rien à
# installer, et surtout rien qui atterrisse dans l'image finale — seul le jar
# vérifié en sort, par le COPY --from de l'étape suivante. L'image livrée
# n'embarque donc ni curl ni wget en plus de ce qu'Alpine contient déjà.
#
# Maven Central plutôt que la release GitHub : une URL qui contient la version
# désigne un fichier immuable (Central interdit de republier une version), là
# où `releases/latest` changerait sous nos pieds.
FROM ${RUNTIME_IMAGE} AS otel-agent

ARG OTEL_JAVAAGENT_VERSION
ARG OTEL_JAVAAGENT_SHA256

# ⚠️ Deux espaces entre l'empreinte et le nom : c'est le format que `sha256sum
# -c` attend. En cas d'écart, le RUN échoue et le build s'arrête — un agent
# altéré ne peut pas se retrouver dans l'image, puisqu'il s'exécuterait avec
# les droits de l'application et verrait passer chaque requête.
RUN wget -q -O /opentelemetry-javaagent.jar \
      "https://repo1.maven.org/maven2/io/opentelemetry/javaagent/opentelemetry-javaagent/${OTEL_JAVAAGENT_VERSION}/opentelemetry-javaagent-${OTEL_JAVAAGENT_VERSION}.jar" \
    && echo "${OTEL_JAVAAGENT_SHA256}  /opentelemetry-javaagent.jar" | sha256sum -c -

# --- étape 3 : image d'exécution ---
FROM ${RUNTIME_IMAGE} AS back

# Même version majeure que le JDK de compilation.
#
# `apk upgrade` d'abord : l'image Alpine officielle n'est reconstruite qu'à
# chaque version mineure, et les correctifs publiés entre-temps (musl, OpenSSL)
# n'y sont pas. Sans lui, l'image livrée hérite de CVE déjà corrigées en amont.
RUN apk upgrade --no-cache \
    && apk add --no-cache openjdk21-jre-headless \
    && adduser -D -H app

# L'agent est copié AVANT l'application : il change bien plus rarement qu'elle,
# sa couche reste donc en cache d'un build à l'autre (~25 Mo non renvoyés au
# registry à chaque commit).
#
# ⚠️ Sa présence ne l'active PAS. Le CMD plus bas est inchangé : l'agent ne se
# charge que si JAVA_TOOL_OPTIONS=-javaagent:/app/opentelemetry-javaagent.jar
# est posée, ce que fait la ConfigMap Kubernetes. Raison : les jobs k6 de la CI
# démarrent cette image comme service, sans collecteur OTLP ; activé par
# défaut, l'agent y journaliserait en boucle ses échecs d'export et ralentirait
# le démarrage que la mesure de performance chronomètre.
COPY --from=otel-agent /opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar

# Corrélation logs ↔ traces. Quand il est chargé, l'agent ajoute l'identifiant
# de trace et de span au MDC Logback de chaque événement émis pendant une
# requête tracée ; l'encodeur ECS (logback-spring.xml, profil `container`)
# recopie le MDC tel quel dans le JSON. Par défaut les clés s'appellent
# `trace_id` / `span_id`, que Kibana ne relie à rien : ECS attend `trace.id` et
# `span.id` pour ouvrir la trace APM depuis la ligne de log.
#
# Posées ici plutôt que dans la ConfigMap : c'est le format des logs de CETTE
# image, il doit voyager avec elle quel que soit l'orchestrateur. Sans agent,
# ces deux variables ne sont lues par personne — l'image se comporte
# exactement comme avant.
#
# ⚠️ Noms en `*_KEY` : dans l'agent 2.31.1, `otel.instrumentation.common.
# logging.trace-id` (sans `-key`) est dépréciée et disparaît en 3.0 — elle
# marche encore mais écrit un avertissement au démarrage.
#
# ⚠️ Une surcharge par une valeur VIDE n'équivaut pas à « non définie » :
# l'agent prend la chaîne vide pour nom de clé et le JSON contient alors
# `"":"<span id>"`. Pour revenir aux noms par défaut, il faut poser
# explicitement `trace_id` / `span_id`, pas vider la variable.
#
# `trace_flags` (échantillonnage) n'a pas d'équivalent ECS : il garde son nom.
ENV OTEL_INSTRUMENTATION_COMMON_LOGGING_TRACE_ID_KEY=trace.id \
    OTEL_INSTRUMENTATION_COMMON_LOGGING_SPAN_ID_KEY=span.id

# Motif *.jar plutôt que le nom complet : le numéro de version vit dans
# back/build.gradle, et `jar.enabled = false` y garantit qu'une seule archive
# est produite. Un bump de version ne casse donc plus la construction.
COPY --from=build /src/build/libs/*.jar /app/microcrm.jar

WORKDIR /app
USER app

# Port réellement écouté par Spring Boot.
EXPOSE 8080

CMD ["java", "-jar", "/app/microcrm.jar"]
