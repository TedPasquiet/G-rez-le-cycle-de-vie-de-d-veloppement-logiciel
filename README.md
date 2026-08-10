<p align="center">
   <img src="./front/src/favicon.png" width="192px" />
</p>

# MicroCRM (P5 - Expert DevOps - Gérez le cycle de vie de développement logiciel)

MicroCRM est une application de démonstration basique ayant pour être objectif de servir de socle pour le module "P5 - Expert DevOps".

L'application MicroCRM est une implémentation simplifiée d'un ["CRM" (Customer Relationship Management)](https://fr.wikipedia.org/wiki/Gestion_de_la_relation_client). Les fonctionnalités sont limitées à la création, édition et la visualisations des individus liés à des organisations.

![Page d'accueil](./misc/screenshots/screenshot_1.png)
![Édition de la fiche d'un individu](./misc/screenshots/screenshot_2.png)

## Code source

### Organisation

Ce [monorepo](https://en.wikipedia.org/wiki/Monorepo) contient les 2 composantes du projet "MicroCRM":

- La partie serveur (ou "backend"), en Java SpringBoot 3;
- La partie cliente (ou "frontend"), en Angular 17.

Une intégration basique avec Gitlab CI est définie via le fichier [`.gitlab-ci.yml`](./.gitlab-ci.yml).
La configuration du pipeline et les valeurs à externaliser sont détaillées dans
[VARIABILISATION.md](./VARIABILISATION.md).

### Démarrer avec les sources

#### Serveur

##### Dépendances

- [OpenJDK >= 17](https://openjdk.org/)

##### Procédure

1. Se positionner dans le répertoire `back` avec une invite de commande:

   ```shell
   cd back
   ```

2. Construire le JAR:

   ```shell
   # Sur Linux
   ./gradlew build

   # Sur Windows
   gradlew.bat build
   ```

3. Démarrer le service:

   ```shell
   java -jar build/libs/microcrm-*.jar
   ```

Puis ouvrir l'URL http://localhost:8080 dans votre navigateur.

#### Client

##### Dépendances

- [NPM >= 10.2.4](https://www.npmjs.com/)

##### Procédure

1. Se positionner dans le répertoire `front` avec une invite de commande:

   ```shell
   cd front
   ```

2. (La première fois seulement) Installer les dépendances NodeJS:

   ```shell
   npm install
   ```

3. Démarrer le service de développement:

   ```shell
   npx @angular/cli serve
   ```

Puis ouvrir l'URL http://localhost:4200 dans votre navigateur.

### Exécution des tests

#### Client

**Dépendances**

- Google Chrome ou Chromium

Dans votre terminal:

```shell
cd front
CHROME_BIN=</path/to/google/chrome> npm test
```

#### Serveur

Dans votre terminal:

```shell
cd back
./gradlew test
```

#### Tests de performance (k6)

**Dépendances**

- [k6](https://k6.io/) — ou Docker, voir la variante plus bas.

Le serveur doit être démarré. Dans un autre terminal:

```shell
scripts/tests/run_k6.sh                      # test de fumée (défaut)
scripts/tests/run_k6.sh --scenario load      # charge nominale

# Sans installer k6
docker run --rm --network host -v "$PWD:/work" -w /work \
  -e K6_BASE_URL=http://localhost:8080 \
  grafana/k6:2.1.0 run tests/k6/smoke.js
```

Les scénarios sont dans `tests/k6/`, les seuils et la démarche dans
[QUALITY.md](./QUALITY.md) §5.

### Images Docker

Chaque application a **son propre Dockerfile**, dans son dossier. Il n'y a pas
de Dockerfile à la racine du dépôt, et pas d'image « tout en un ».

#### Le plus simple : la stack complète

```shell
docker compose up --build
```

Le front est servi sur http://localhost:4200, l'API sur http://localhost:8080.
Les ports et les noms d'images se règlent sans toucher au compose, via un
fichier `.env` — voir [`.env.example`](./.env.example).

#### Image du serveur

```shell
docker build -t microcrm-back ./back
docker run --rm -p 8080:8080 microcrm-back
```

L'API est disponible sur http://localhost:8080.

#### Image du client

```shell
docker build -t microcrm-front ./front
docker run --rm -p 4200:80 -e FRONT_API_BASE_URL=http://localhost:8080 microcrm-front
```

Le front est disponible sur http://localhost:4200. La variable
`FRONT_API_BASE_URL` est facultative : sans elle, le front vise
`http://localhost:8080`.

### Les choix de conteneurisation, et pourquoi

#### Une image par application, pas une image commune

Le front et le back n'ont ni le même cycle de vie, ni les mêmes dépendances, ni
la même charge. Les fusionner obligerait à redéployer l'un pour corriger
l'autre, et imposerait un superviseur de processus dans le conteneur — donc un
conteneur qui ne meurt plus quand son application meurt, ce qui prive
Kubernetes de son principal signal de panne.

#### Construction en deux étapes

Chaque Dockerfile compile dans une image outillée (Gradle, Node) puis ne copie
que l'artefact dans une image d'exécution minimale. Ni le JDK, ni npm, ni les
sources ne se retrouvent dans l'image livrée. Le front pèse ainsi 85 Mo, dont
84,9 pour Caddy lui-même : l'application n'ajoute que quelques centaines de
kilo-octets.

#### Des versions figées, jamais `latest`

Les images de base sont épinglées (`gradle:8.14.5-jdk21`, `node:22-alpine`,
`caddy:2-alpine`, `alpine:3.19`) et alignées sur les variables du
[`.gitlab-ci.yml`](./.gitlab-ci.yml) : le code est compilé avec la version
exacte qui a servi à le tester. Un tag flottant fait casser une construction
sans qu'aucun commit ne l'explique, et rend deux analyses incomparables. Les
versions restent surchargeables au build via `--build-arg`.

#### Un utilisateur non privilégié dans les deux images

Les deux conteneurs tournent en UID 1000, le même que celui déclaré dans les
manifestes Kubernetes : le comportement est identique sous Docker et sous
Kubernetes. Au déploiement s'ajoutent un système de fichiers en lecture seule et
la suppression de toutes les capabilities.

#### Un `.dockerignore` par application

Les jobs de construction utilisent `--context ./back` et `--context ./front`, or
Docker ne lit que le `.dockerignore` situé à la racine du contexte : celui du
dépôt ne s'applique jamais à ces builds. Sans ces deux fichiers, le contexte du
front atteint 1 195 Mo — essentiellement le cache Angular et `node_modules`, que
l'image régénère de toute façon. Avec, il tombe à 0,6 Mo.

#### La configuration entre au démarrage, pas à la construction

L'URL de l'API n'est pas compilée dans le bundle : Caddy la sert dans un
`/config.json` que l'application lit avant de démarrer. Une seule image est donc
construite, testée, puis déployée telle quelle en staging comme en production —
seule la variable d'environnement change. Reconstruire une image pour changer
d'environnement reviendrait à déployer autre chose que ce qui a été testé.

Le détail de ces choix est dans [ARCHITECTURE.md](./ARCHITECTURE.md) §3, et la
démarche de configuration dans [VARIABILISATION.md](./VARIABILISATION.md).
