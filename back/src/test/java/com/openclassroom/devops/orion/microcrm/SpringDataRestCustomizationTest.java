package com.openclassroom.devops.orion.microcrm;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.data.rest.core.config.RepositoryRestConfiguration;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

/**
 * Test unitaire de {@link SpringDataRestCustomization} : on inspecte la
 * configuration produite plutôt que son effet sur des requêtes HTTP.
 *
 * <p>{@link CorsPolicyTest} vérifie déjà le comportement observable — ce qu'un
 * navigateur obtient. Il ne dit rien des réglages qui n'apparaissent pas dans
 * une réponse de préflight : la durée de mise en cache, les en-têtes exposés,
 * l'exposition des identifiants. Ce sont pourtant des valeurs qu'on peut perdre
 * silencieusement en réécrivant la méthode.
 *
 * <p>C'est aussi ce test qui tue les mutants que PIT laissait survivre sur
 * cette classe (voir la section pitest de build.gradle). Il en reste un, et un
 * seul : la suppression de l'appel {@code RepositoryRestConfigurer.super...}
 * en fin de méthode, dont l'implémentation par défaut est vide. Aucun test ne
 * peut le tuer puisqu'il ne change rien — c'est un mutant équivalent, la limite
 * connue de l'exercice.
 */
class SpringDataRestCustomizationTest {

    /** Rend accessible la carte des configurations, protégée dans CorsRegistry. */
    private static final class InspectableCorsRegistry extends CorsRegistry {
        @Override
        protected Map<String, CorsConfiguration> getCorsConfigurations() {
            return super.getCorsConfigurations();
        }
    }

    private CorsConfiguration configureWith(String... origines) {
        InspectableCorsRegistry registry = new InspectableCorsRegistry();
        RepositoryRestConfiguration config = mock(RepositoryRestConfiguration.class);

        new SpringDataRestCustomization(List.of(origines))
                .configureRepositoryRestConfiguration(config, registry);

        Map<String, CorsConfiguration> configurations = registry.getCorsConfigurations();
        assertEquals(1, configurations.size(), "une seule règle, appliquée à toute l'API");
        CorsConfiguration cors = configurations.get("/**");
        assertNotNull(cors, "la règle porte sur le motif /**");
        return cors;
    }

    @Test
    @DisplayName("Les origines injectées sont reportées telles quelles dans la règle CORS")
    void injectedOriginsEndUpInTheCorsRule() {
        CorsConfiguration cors = configureWith("https://crm.example.org", "https://admin.example.org");

        assertEquals(List.of("https://crm.example.org", "https://admin.example.org"),
                cors.getAllowedOrigins());
    }

    @Test
    @DisplayName("Aucun joker n'est posé sur les origines")
    void noWildcardOriginIsConfigured() {
        // Le point de sécurité de la classe : l'API n'a pas d'authentification,
        // une origine « * » la rendrait lisible par n'importe quel site.
        CorsConfiguration cors = configureWith("https://crm.example.org");

        assertTrue(cors.getAllowedOrigins() != null && !cors.getAllowedOrigins().contains("*"));
        assertNull(cors.getAllowedOriginPatterns(),
                "aucun motif d'origine non plus, qui contournerait la liste explicite");
    }

    @Test
    @DisplayName("Les méthodes autorisées sont exactement celles dont le front a besoin")
    void allowedMethodsAreExactlyWhatTheFrontNeeds() {
        CorsConfiguration cors = configureWith("https://crm.example.org");

        assertEquals(List.of("GET", "POST", "PUT", "PATCH", "DELETE"), cors.getAllowedMethods());
    }

    @Test
    @DisplayName("Les identifiants de session ne sont pas autorisés")
    void credentialsAreNotAllowed() {
        CorsConfiguration cors = configureWith("https://crm.example.org");

        assertEquals(Boolean.FALSE, cors.getAllowCredentials());
    }

    @Test
    @DisplayName("Le préflight est mis en cache une heure et Allow-Origin est exposé")
    void preflightIsCachedAndAllowOriginIsExposed() {
        // Valeurs invisibles dans les tests HTTP : maxAge évite un préflight
        // avant chaque écriture du front, exposedHeaders rend l'en-tête lisible
        // au JavaScript appelant.
        CorsConfiguration cors = configureWith("https://crm.example.org");

        assertEquals(3600L, cors.getMaxAge());
        assertEquals(List.of("Access-Control-Allow-Origin"), cors.getExposedHeaders());
    }

    @Test
    @DisplayName("Les identifiants des deux entités sont exposés dans le JSON")
    void idsOfBothEntitiesAreExposed() {
        // exposeIdsFor : sans cet appel, le JSON ne contient plus le champ `id`
        // et le front ne sait plus construire ses liens de navigation.
        InspectableCorsRegistry registry = new InspectableCorsRegistry();
        RepositoryRestConfiguration config = mock(RepositoryRestConfiguration.class);

        new SpringDataRestCustomization(List.of("https://crm.example.org"))
                .configureRepositoryRestConfiguration(config, registry);

        verify(config).exposeIdsFor(Person.class, Organization.class);
    }

    @Test
    @DisplayName("La liste d'origines reçue est recopiée, pas conservée par référence")
    void theSuppliedOriginListIsDefensivelyCopied() {
        // List.copyOf dans le constructeur : une liste modifiable passée par
        // Spring ne doit pas pouvoir être élargie après le démarrage.
        List<String> mutable = new java.util.ArrayList<>(List.of("https://crm.example.org"));
        SpringDataRestCustomization customization = new SpringDataRestCustomization(mutable);

        mutable.add("https://evil.example.net");

        InspectableCorsRegistry registry = new InspectableCorsRegistry();
        customization.configureRepositoryRestConfiguration(
                mock(RepositoryRestConfiguration.class), registry);

        assertEquals(List.of("https://crm.example.org"),
                registry.getCorsConfigurations().get("/**").getAllowedOrigins());
    }
}
