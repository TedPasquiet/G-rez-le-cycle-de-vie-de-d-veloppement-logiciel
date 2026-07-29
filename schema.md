# Schéma — Chaîne CI/CD normalisée (MicroCRM)

Chaque étape du cycle de développement est traduite en _stage_ GitLab CI, outillée
et assortie d'un critère bloquant. La sécurité est déplacée au plus tôt
(**shift-left / DevSecOps**), le déploiement est automatisé jusqu'à la validation PO.

Source visuelle : https://claude.ai/code/artifact/831ad9ad-9664-4e62-b252-80c239ff19fb

## Workflow complet

```mermaid
flowchart TD
    %% ───────────── 01 · Amont produit ─────────────
    subgraph P1["01 · AMONT PRODUIT"]
        direction TB
        A1["Backlog"]
        A2["Priorisation<br/>story → branche + Merge Request"]
        A3["Développement<br/>code + tests unitaires<br/>pre-commit · lint · format"]
        A1 --> A2 --> A3
    end

    %% ───────────── 02 · Intégration continue ─────────────
    subgraph P2["02 · INTÉGRATION CONTINUE — à chaque Merge Request"]
        direction TB
        B1["build<br/>Gradle · Angular CLI"]
        B2["test<br/>JUnit · Jasmine/Karma<br/>couverture ≥ seuil défini"]
        B3["quality · analyse statique<br/>SonarQube · SpotBugs"]
        B4["dependency-scan · SCA<br/>OWASP Dependency-Check · Snyk"]
        B5["package<br/>2 images : front + back<br/>tag = CI_COMMIT_SHA"]
        B6["image-scan<br/>Trivy · 0 CVE HIGH/CRITICAL"]
        QG{"Quality Gate<br/>tous les contrôles au vert ?"}
        B1 --> B2 --> B3 --> B4 --> B5 --> B6 --> QG
    end

    %% ───────────── 03 · Déploiement continu ─────────────
    subgraph P3["03 · DÉPLOIEMENT CONTINU — GitFlow · Docker Compose"]
        direction TB
        C1["deploy-staging<br/>auto sur develop<br/>healthcheck /actuator/health"]
        C2["integration<br/>tests fonctionnels + E2E<br/>Cypress/Playwright · Newman"]
        PO{"Validation PO<br/>job manuel"}
        C3["deploy-prod<br/>manuel · tag de release<br/>image lockée par digest"]
        C1 --> C2 --> PO
    end

    %% ───────────── 04 · Exploitation ─────────────
    subgraph P4["04 · EXPLOITATION"]
        direction TB
        D1["monitoring & supervision<br/>Spring Boot Actuator<br/>Prometheus / Grafana"]
    end

    %% ───────────── Transitions entre phases ─────────────
    A3 --> B1
    QG -->|"✗ échec — feedback immédiat"| A3
    QG -->|"✓ succès — merge sur develop"| C1
    PO -->|"✗ refus"| A3
    PO -->|"✓ approbation — tag release"| C3
    C3 --> D1
    D1 -.->|"incidents / retours prod"| A1

    %% ───────────── Styles ─────────────
    classDef ci     fill:#d8efeb,stroke:#0f766e,stroke-width:2px,color:#0b5049
    classDef sec    fill:#fbe6cd,stroke:#b45309,stroke-width:2px,color:#7c3a06
    classDef gate   fill:#d5ecdd,stroke:#15803d,stroke-width:2px,color:#0f5227
    classDef deploy fill:#e2e0fb,stroke:#4f46e5,stroke-width:2px,color:#312c9e
    classDef ops    fill:#e8ddfb,stroke:#7c3aed,stroke-width:2px,color:#54209e
    classDef prod   fill:#f5f8f8,stroke:#5b6c69,stroke-width:1px,color:#13201e

    class A1,A2,A3 prod
    class B1,B2,B5 ci
    class B3,B4,B6 sec
    class QG,PO gate
    class C1,C2,C3 deploy
    class D1 ops
```

**Légende des couleurs**

| Couleur    | Nature                              |
| ---------- | ----------------------------------- |
| Gris       | Amont produit (hors CI)             |
| Vert d'eau | Intégration continue                |
| Orange     | Sécurité — shift-left / DevSecOps   |
| Vert       | Quality gate / validation bloquante |
| Indigo     | Déploiement continu                 |
| Violet     | Exploitation                        |

## Table de normalisation — cycle → GitLab CI

| Étape du cycle                   | Stage GitLab                 | Outils                          | Critère bloquant                  |
| -------------------------------- | ---------------------------- | ------------------------------- | --------------------------------- |
| Développement                    | _(local)_                    | pre-commit, lint                | Format + lint OK avant push       |
| Build                            | `build`                      | Gradle, Angular CLI             | Compilation sans erreur           |
| Tests unitaires                  | `test`                       | JUnit, Jasmine/Karma            | Couverture ≥ seuil (ex. 80 %)     |
| Analyse statique                 | `quality`                    | SonarQube, SpotBugs             | Quality Gate Sonar au vert        |
| Analyse des dépendances          | `dependency-scan`            | OWASP DC, Snyk                  | 0 CVE critique / haute            |
| Construction des images          | `package`                    | Docker/Kaniko, Registry         | Build OK, tag = commit SHA        |
| Analyse des images               | `image-scan`                 | Trivy                           | 0 CVE HIGH/CRITICAL               |
| Quality gate                     | `quality-gate`               | règles GitLab (`needs`)         | Tous les jobs amont au vert       |
| Déploiement staging              | `deploy-staging` · `develop` | GitLab Env, Docker Compose      | Healthcheck `/actuator/health` OK |
| Tests fonctionnels & intégration | `integration`                | Cypress/Playwright, Newman      | Scénarios E2E + API passants      |
| Validation PO                    | `validate` (manual)          | job manuel GitLab               | Approbation explicite du PO       |
| Déploiement production           | `deploy-prod` (manual · tag) | GitLab Env prod, Docker Compose | Healthcheck OK, digest locké      |
| Monitoring & supervision         | _(post-deploy)_              | Actuator, Prometheus/Grafana    | Alerting actif, SLO surveillés    |

---

> ⚠️ **État actuel du repo.** Ce schéma décrit la chaîne **cible**. Le
> `.gitlab-ci.yml` en place ne contient que 2 stages (`test`, `build`) et
> 4 jobs (`test-front`, `test-back`, `build-front`, `build-back`) — ni `package`,
> ni scans de sécurité, ni stage `deploy`. Les règles GitFlow (`.rules_test` /
> `.rules_build`) sont en revanche déjà posées et servent de base au déclenchement.
