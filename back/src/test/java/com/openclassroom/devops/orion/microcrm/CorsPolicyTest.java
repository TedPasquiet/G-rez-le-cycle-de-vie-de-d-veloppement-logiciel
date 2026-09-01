package com.openclassroom.devops.orion.microcrm;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.options;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Politique CORS déclarée par {@link SpringDataRestCustomization}.
 *
 * <p>C'est le seul contrôle d'accès de l'application : l'API n'a ni
 * authentification ni autorisation. Une allowlist trop large y est donc une
 * ouverture réelle, et une allowlist trop étroite casse le front sans qu'aucun
 * test du back ne le voie. Les deux sens sont vérifiés ici.
 */
@SpringBootTest
@AutoConfigureMockMvc
class CorsPolicyTest {

    /** Origine déclarée dans application.properties. */
    private static final String ORIGINE_AUTORISEE = "http://localhost:4200";

    @Autowired
    private MockMvc mockMvc;

    @ParameterizedTest(name = "{0} {1} passe le préflight")
    @CsvSource({
        "GET,    /persons",
        "POST,   /persons",
        "GET,    /persons/1",
        "PUT,    /persons/1",
        "PATCH,  /persons/1",
        "DELETE, /persons/1",
        "POST,   /organizations/1/persons",
        "DELETE, /organizations/1/persons/1",
    })
    @DisplayName("Chaque appel réellement émis par le front passe le préflight")
    void everyCallTheFrontMakesPassesPreflight(String methode, String chemin) throws Exception {
        // Le préflight est résolu endpoint par endpoint, pas globalement : Spring
        // cherche le handler correspondant à la méthode ET au chemin demandés.
        // Autoriser PUT dans la politique ne suffit donc pas — il faut que la
        // route existe. La liste ci-dessus reprend les appels de
        // PersonService et OrganizationService, un par un.
        mockMvc.perform(options(chemin)
                .header("Origin", ORIGINE_AUTORISEE)
                .header("Access-Control-Request-Method", methode))
                .andExpect(status().isOk())
                .andExpect(header().string("Access-Control-Allow-Origin", ORIGINE_AUTORISEE));
    }

    @ParameterizedTest(name = "{0} est refusée en préflight")
    @ValueSource(strings = { "TRACE", "HEAD" })
    @DisplayName("Les méthodes hors allowlist sont refusées")
    void methodsOutsideTheAllowlistAreRejected(String methode) throws Exception {
        mockMvc.perform(options("/persons")
                .header("Origin", ORIGINE_AUTORISEE)
                .header("Access-Control-Request-Method", methode))
                .andExpect(status().isForbidden());
    }

    @ParameterizedTest(name = "{0} est refusée")
    @ValueSource(strings = {
        "http://evil.example.net",
        "https://localhost:4200",
        "http://localhost:4201",
    })
    @DisplayName("Une origine non listée est refusée, y compris une variante proche")
    void anUnlistedOriginIsRejected(String origine) throws Exception {
        // Le schéma, l'hôte et le port doivent correspondre exactement : c'est
        // ce qui distingue une allowlist d'un joker « * ».
        mockMvc.perform(options("/persons")
                .header("Origin", origine)
                .header("Access-Control-Request-Method", "GET"))
                .andExpect(status().isForbidden());
    }

    @Test
    @DisplayName("Le préflight autorise l'en-tête Content-Type, requis par les écritures")
    void preflightAllowsTheContentTypeHeader() throws Exception {
        // OrganizationService.addPerson envoie Content-Type: text/uri-list ;
        // les enregistrements envoient application/json. Sans cet en-tête
        // autorisé, le navigateur bloque la requête avant même de l'émettre.
        mockMvc.perform(options("/organizations/1/persons")
                .header("Origin", ORIGINE_AUTORISEE)
                .header("Access-Control-Request-Method", "POST")
                .header("Access-Control-Request-Headers", "content-type"))
                .andExpect(status().isOk())
                .andExpect(header().string("Access-Control-Allow-Headers",
                        org.hamcrest.Matchers.containsStringIgnoringCase("content-type")));
    }

    @Test
    @DisplayName("Les identifiants de session ne sont jamais autorisés")
    void credentialsAreNeverAllowed() throws Exception {
        // allowCredentials(false) : l'API est publique et sans session. Passer
        // ce réglage à true, combiné à une allowlist élargie, exposerait les
        // cookies de l'utilisateur à un site tiers.
        mockMvc.perform(options("/persons")
                .header("Origin", ORIGINE_AUTORISEE)
                .header("Access-Control-Request-Method", "GET"))
                .andExpect(status().isOk())
                .andExpect(header().doesNotExist("Access-Control-Allow-Credentials"));
    }

    @Test
    @DisplayName("Une requête simple sans en-tête Origin passe (appel serveur à serveur)")
    void aRequestWithoutOriginIsNotAffected() throws Exception {
        // CORS est une protection du navigateur : curl, les sondes Kubernetes
        // et k6 n'envoient pas d'Origin et ne doivent pas être bloqués.
        mockMvc.perform(get("/persons"))
                .andExpect(status().isOk());
    }
}
