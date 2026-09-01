package com.openclassroom.devops.orion.microcrm;

import static java.util.Objects.requireNonNull;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.annotation.Transactional;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Cycle de vie complet d'une personne vu du client HTTP : écriture, mise à jour,
 * suppression, pagination et tri, et comportement sur entrée invalide.
 *
 * <p>{@link PersonRestApiTest} couvre la lecture et la configuration CORS ; on
 * sépare ici tout ce qui écrit, pour pouvoir annuler la transaction en fin de
 * test sans changer la nature de la classe existante.
 */
@SpringBootTest
@AutoConfigureMockMvc
@Transactional
class PersonRestLifecycleTest {

    @Autowired
    private MockMvc mockMvc;

    private String createPerson(String json) throws Exception {
        String location = requireNonNull(mockMvc.perform(post("/persons")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json))
                .andExpect(status().isCreated())
                .andReturn().getResponse().getHeader("Location"),
                "l'en-tête Location est absent de la réponse 201");
        return location.substring(location.lastIndexOf('/') + 1);
    }

    @Test
    @DisplayName("PUT remplace la ressource : les champs absents du corps sont effacés")
    void putReplacesTheWholeResource() throws Exception {
        // Piège classique de Spring Data REST, et raison pour laquelle
        // PersonService.save() renvoie TOUS les champs et pas seulement ceux
        // modifiés : un PUT partiel effacerait le reste.
        String id = createPerson("""
                {"firstName":"John","lastName":"Doe","email":"put@example.net",
                 "phone":"+33600000000","bio":"Biographie initiale"}
                """);

        mockMvc.perform(put("/persons/" + id)
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {"firstName":"John","lastName":"Doe","email":"put@example.net"}
                        """))
                .andExpect(status().is2xxSuccessful());

        mockMvc.perform(get("/persons/" + id))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.firstName").value("John"))
                .andExpect(jsonPath("$.phone").doesNotExist())
                .andExpect(jsonPath("$.bio").doesNotExist());
    }

    @Test
    @DisplayName("PATCH ne modifie que les champs fournis")
    void patchOnlyUpdatesTheSuppliedFields() throws Exception {
        String id = createPerson("""
                {"firstName":"John","lastName":"Doe","email":"patch@example.net",
                 "phone":"+33600000000","bio":"Biographie initiale"}
                """);

        mockMvc.perform(patch("/persons/" + id)
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"bio\":\"Biographie corrigee\"}"))
                .andExpect(status().is2xxSuccessful());

        mockMvc.perform(get("/persons/" + id))
                .andExpect(jsonPath("$.bio").value("Biographie corrigee"))
                .andExpect(jsonPath("$.phone").value("+33600000000"))
                .andExpect(jsonPath("$.email").value("patch@example.net"));
    }

    @Test
    @DisplayName("DELETE supprime la personne, qui devient introuvable")
    void deleteRemovesThePerson() throws Exception {
        String id = createPerson("""
                {"firstName":"Temp","lastName":"Orary","email":"delete@example.net"}
                """);

        mockMvc.perform(delete("/persons/" + id)).andExpect(status().isNoContent());

        mockMvc.perform(get("/persons/" + id)).andExpect(status().isNotFound());
        mockMvc.perform(get("/persons/search/findByEmail").param("email", "delete@example.net"))
                .andExpect(status().isNotFound());
    }

    @Test
    @DisplayName("DELETE sur une personne inexistante retourne 404")
    void deleteOnUnknownPersonReturnsNotFound() throws Exception {
        mockMvc.perform(delete("/persons/999999")).andExpect(status().isNotFound());
    }

    @Test
    @DisplayName("Un corps JSON malformé retourne 400 et non 500")
    void malformedJsonReturnsBadRequest() throws Exception {
        mockMvc.perform(post("/persons")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"firstName\": "))
                .andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("La pagination est pilotable par les paramètres page et size")
    void collectionIsPageable() throws Exception {
        createPerson("{\"firstName\":\"A\",\"lastName\":\"A\",\"email\":\"page-a@example.net\"}");
        createPerson("{\"firstName\":\"B\",\"lastName\":\"B\",\"email\":\"page-b@example.net\"}");

        mockMvc.perform(get("/persons").param("page", "0").param("size", "1"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.persons.length()").value(1))
                .andExpect(jsonPath("$.page.size").value(1))
                .andExpect(jsonPath("$._links.next").exists());
    }

    @Test
    @DisplayName("Le tri par nom est exposé par PagingAndSortingRepository")
    void collectionIsSortable() throws Exception {
        createPerson("{\"firstName\":\"Zoe\",\"lastName\":\"Zulu\",\"email\":\"sort-z@example.net\"}");
        createPerson("{\"firstName\":\"Alice\",\"lastName\":\"Alpha\",\"email\":\"sort-a@example.net\"}");

        mockMvc.perform(get("/persons").param("sort", "lastName,asc").param("size", "1"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.persons[0].lastName").value("Alpha"));
    }

    @Test
    @DisplayName("DELETE sur la collection n'est pas routé : 404, pas une suppression de masse")
    void deleteOnTheCollectionIsNotRouted() throws Exception {
        // Spring Data REST n'expose aucun handler pour DELETE /persons : la
        // requête n'est associée à aucune route et retourne 404 (et non 405).
        // Ce qui compte ici est qu'un appel accidentel ne vide pas la table.
        mockMvc.perform(delete("/persons"))
                .andExpect(status().isNotFound());

        mockMvc.perform(get("/persons"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.page.totalElements").value(
                        org.hamcrest.Matchers.greaterThan(0)));
    }
}
