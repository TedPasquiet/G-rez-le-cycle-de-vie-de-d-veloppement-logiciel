package com.openclassroom.devops.orion.microcrm;

import java.net.URI;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.options;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Tests de la couche REST exposée automatiquement par Spring Data REST.
 * Vérifient les endpoints HAL, l'exposition des identifiants configurée dans
 * {@link SpringDataRestCustomization} et la configuration CORS.
 */
@SpringBootTest
@AutoConfigureMockMvc
class PersonRestApiTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("GET /persons retourne une collection HAL paginée")
    void getPersonsReturnsHalCollection() throws Exception {
        mockMvc.perform(get("/persons"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.persons").isArray())
                .andExpect(jsonPath("$.page.size").exists())
                .andExpect(jsonPath("$.page.totalElements").exists());
    }

    @Test
    @DisplayName("Les identifiants sont exposés dans le JSON (exposeIdsFor)")
    void personIdsAreExposedInPayloads() throws Exception {
        mockMvc.perform(get("/persons"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.persons[0].id").exists());
    }

    @Test
    @DisplayName("Les champs métier de /persons restent plats et non imbriqués")
    void personPayloadKeepsItsFlatShape() throws Exception {
        // Contrat consommé par le front : les champs sont à la racine de l'objet.
        // Le getter Person.getOrganizations() expose l'association en tant que
        // LIEN (_links.organizations), jamais en objet imbriqué : aucun risque
        // de récursion infinie Person -> Organization -> Person.
        mockMvc.perform(get("/persons"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.persons[0].firstName").exists())
                .andExpect(jsonPath("$._embedded.persons[0].lastName").exists())
                .andExpect(jsonPath("$._embedded.persons[0].email").exists())
                .andExpect(jsonPath("$._embedded.persons[0].organizations").doesNotExist())
                .andExpect(jsonPath("$._embedded.persons[0]._links.self").exists())
                .andExpect(jsonPath("$._embedded.persons[0]._links.organizations").exists());
    }

    @Test
    @DisplayName("L'association organizations d'une personne est navigable")
    void personOrganizationsAssociationIsNavigable() throws Exception {
        mockMvc.perform(get("/persons/1/organizations"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.organizations").isArray());
    }

    @Test
    @DisplayName("GET /organizations expose l'organisation du jeu de données initial")
    void getOrganizationsReturnsSeededOrganization() throws Exception {
        mockMvc.perform(get("/organizations"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.organizations[0].id").exists())
                .andExpect(jsonPath("$._embedded.organizations[0].name").exists());
    }

    @Test
    @DisplayName("L'endpoint de recherche findByEmail est publié et exploitable")
    void findByEmailSearchEndpointIsExposed() throws Exception {
        mockMvc.perform(get("/persons/search/findByEmail").param("email", "jdoe@example.net"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.email").value("jdoe@example.net"));
    }

    @Test
    @DisplayName("findByEmail sur un email inconnu retourne 404")
    void findByEmailReturnsNotFoundForUnknownEmail() throws Exception {
        mockMvc.perform(get("/persons/search/findByEmail").param("email", "nobody@example.net"))
                .andExpect(status().isNotFound());
    }

    @Test
    @DisplayName("Le point d'entrée de l'API liste les deux ressources")
    void apiRootAdvertisesBothResources() throws Exception {
        mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._links.persons").exists())
                .andExpect(jsonPath("$._links.organizations").exists());
    }

    @Test
    @DisplayName("POST /persons crée une personne, retourne 201 et un en-tête Location")
    void postPersonCreatesAResource() throws Exception {
        // Spring Data REST renvoie un corps vide à la création tant que
        // `spring.data.rest.return-body-on-create=true` n'est pas positionné :
        // le client doit suivre l'en-tête Location.
        String location = mockMvc.perform(post("/persons")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {"firstName":"Jane","lastName":"Roe","email":"jroe-post@example.net"}
                        """))
                .andExpect(status().isCreated())
                .andExpect(header().exists("Location"))
                .andReturn()
                .getResponse()
                .getHeader("Location");

        mockMvc.perform(get(URI.create(location)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.firstName").value("Jane"))
                .andExpect(jsonPath("$.email").value("jroe-post@example.net"));

        mockMvc.perform(get("/persons/search/findByEmail").param("email", "jroe-post@example.net"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.lastName").value("Roe"));
    }

    @Test
    @DisplayName("GET sur une personne inexistante retourne 404")
    void getUnknownPersonReturnsNotFound() throws Exception {
        mockMvc.perform(get("/persons/999999"))
                .andExpect(status().isNotFound());
    }

    @Test
    @DisplayName("Le préflight CORS autorise une origine tierce")
    void corsPreflightAllowsCrossOriginRequests() throws Exception {
        mockMvc.perform(options("/persons")
                .header("Origin", "http://localhost:4200")
                .header("Access-Control-Request-Method", "GET"))
                .andExpect(status().isOk())
                .andExpect(header().exists("Access-Control-Allow-Origin"));
    }

    @Test
    @DisplayName("Le préflight CORS rejette une méthode non autorisée (PUT)")
    void corsPreflightRejectsUnlistedMethod() throws Exception {
        // La configuration n'autorise que GET, POST, PATCH, DELETE.
        mockMvc.perform(options("/persons")
                .header("Origin", "http://localhost:4200")
                .header("Access-Control-Request-Method", "PUT"))
                .andExpect(status().isForbidden());
    }
}
