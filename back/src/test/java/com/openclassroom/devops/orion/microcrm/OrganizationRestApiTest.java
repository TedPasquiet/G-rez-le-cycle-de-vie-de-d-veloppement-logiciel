package com.openclassroom.devops.orion.microcrm;

import java.net.URI;

import static java.util.Objects.requireNonNull;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
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
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Contrat REST de la ressource {@code /organizations}, y compris les endpoints
 * d'association que le front appelle pour rattacher et détacher une personne.
 *
 * <p>Ces endpoints sont générés par Spring Data REST : aucune ligne de code du
 * dépôt ne les décrit, donc rien ne signale une régression — ni le compilateur,
 * ni Checkstyle, ni SpotBugs. Les tests ci-dessous sont la seule description
 * exécutable du contrat sur lequel {@code organization.service.ts} s'appuie.
 *
 * <p>{@code @Transactional} : chaque test est annulé en fin d'exécution, sinon
 * les écritures fuiraient vers les autres classes de test qui partagent la même
 * base HSQLDB en mémoire.
 */
@SpringBootTest
@AutoConfigureMockMvc
@Transactional
class OrganizationRestApiTest {

    @Autowired
    private MockMvc mockMvc;

    /** Crée une organisation et retourne son identifiant. */
    private String createOrganization(String name) throws Exception {
        String location = requireNonNull(mockMvc.perform(post("/organizations")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"" + name + "\"}"))
                .andExpect(status().isCreated())
                .andReturn().getResponse().getHeader("Location"),
                "l'en-tête Location est absent de la réponse 201");
        return lastSegment(location);
    }

    /** Crée une personne et retourne son identifiant. */
    private String createPerson(String email) throws Exception {
        String location = requireNonNull(mockMvc.perform(post("/persons")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"firstName\":\"Test\",\"lastName\":\"Subject\",\"email\":\"" + email + "\"}"))
                .andExpect(status().isCreated())
                .andReturn().getResponse().getHeader("Location"),
                "l'en-tête Location est absent de la réponse 201");
        return lastSegment(location);
    }

    private static String lastSegment(String location) {
        return location.substring(location.lastIndexOf('/') + 1);
    }

    /** Rattache une personne à une organisation par le lien d'association. */
    private void attach(String orgId, String personId) throws Exception {
        mockMvc.perform(post("/organizations/" + orgId + "/persons")
                .contentType("text/uri-list")
                .content("http://localhost/persons/" + personId))
                .andExpect(status().isNoContent());
    }

    @Test
    @DisplayName("GET /organizations retourne une collection HAL paginée")
    void getOrganizationsReturnsHalCollection() throws Exception {
        mockMvc.perform(get("/organizations"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$._embedded.organizations").isArray())
                .andExpect(jsonPath("$.page.totalElements").exists());
    }

    @Test
    @DisplayName("POST puis GET : l'organisation créée est relisible sur son Location")
    void postOrganizationCreatesAReadableResource() throws Exception {
        String location = requireNonNull(mockMvc.perform(post("/organizations")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"Vega Ltd\"}"))
                .andExpect(status().isCreated())
                .andExpect(header().exists("Location"))
                .andReturn().getResponse().getHeader("Location"),
                "l'en-tête Location est absent de la réponse 201");

        mockMvc.perform(get(URI.create(location)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.name").value("Vega Ltd"))
                .andExpect(jsonPath("$.id").exists())
                .andExpect(jsonPath("$._links.persons").exists());
    }

    @Test
    @DisplayName("PUT remplace le nom de l'organisation")
    void putReplacesTheOrganizationName() throws Exception {
        String id = createOrganization("Nom initial");

        mockMvc.perform(put("/organizations/" + id)
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"Nom corrige\"}"))
                .andExpect(status().is2xxSuccessful());

        mockMvc.perform(get("/organizations/" + id))
                .andExpect(jsonPath("$.name").value("Nom corrige"));
    }

    @Test
    @DisplayName("PATCH modifie le nom sans toucher aux membres")
    void patchUpdatesTheNameAndKeepsMembers() throws Exception {
        String orgId = createOrganization("Nom initial");
        attach(orgId, createPerson("patch-member@example.net"));

        mockMvc.perform(patch("/organizations/" + orgId)
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"Nom corrige\"}"))
                .andExpect(status().is2xxSuccessful());

        mockMvc.perform(get("/organizations/" + orgId))
                .andExpect(jsonPath("$.name").value("Nom corrige"));
        mockMvc.perform(get("/organizations/" + orgId + "/persons"))
                .andExpect(jsonPath("$._embedded.persons[0].email").value("patch-member@example.net"));
    }

    @Test
    @DisplayName("GET sur une organisation inexistante retourne 404")
    void getUnknownOrganizationReturnsNotFound() throws Exception {
        mockMvc.perform(get("/organizations/999999"))
                .andExpect(status().isNotFound());
    }

    @Test
    @DisplayName("DELETE supprime une organisation sans membre")
    void deleteRemovesAnEmptyOrganization() throws Exception {
        String id = createOrganization("A supprimer");

        mockMvc.perform(delete("/organizations/" + id)).andExpect(status().isNoContent());
        mockMvc.perform(get("/organizations/" + id)).andExpect(status().isNotFound());
    }

    @Test
    @DisplayName("DELETE d'une organisation peuplée réussit et laisse ses membres en base")
    void deleteAPopulatedOrganizationSucceedsAndKeepsItsMembers() throws Exception {
        // Test de non-régression. Avec CascadeType.ALL sur Organization.persons,
        // cet appel — celui du bouton « supprimer » de la page organisation du
        // front — répondait HTTP 500 : la cascade de suppression parcourait la
        // liste des membres pendant que le hook @PreRemove de Person la modifiait.
        String orgId = createOrganization("Peuplée");
        String personId = createPerson("survivor@example.net");
        attach(orgId, personId);

        mockMvc.perform(delete("/organizations/" + orgId)).andExpect(status().isNoContent());

        mockMvc.perform(get("/organizations/" + orgId)).andExpect(status().isNotFound());
        mockMvc.perform(get("/persons/" + personId))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.email").value("survivor@example.net"));
    }

    /**
     * Sémantique des endpoints d'association. Spring Data REST distingue POST et
     * PUT sur {@code /organizations/{id}/persons}, et n'accepte le détachement
     * que du côté propriétaire du many-to-many. Les trois tests suivants fixent
     * ces règles, qui déterminent quels appels le front doit émettre.
     */
    @Nested
    @DisplayName("Endpoints d'association organisation ↔ personnes")
    class AssociationEndpoints {

        @Test
        @DisplayName("POST text/uri-list AJOUTE un membre sans retirer les autres")
        void postAppendsAMemberWithoutEvictingTheOthers() throws Exception {
            String orgId = createOrganization("Orion Incorporated");
            attach(orgId, createPerson("first@example.net"));

            attach(orgId, createPerson("second@example.net"));

            mockMvc.perform(get("/organizations/" + orgId + "/persons"))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$._embedded.persons.length()").value(2))
                    .andExpect(jsonPath("$._embedded.persons[0].email").value("first@example.net"))
                    .andExpect(jsonPath("$._embedded.persons[1].email").value("second@example.net"));
        }

        @Test
        @DisplayName("PUT text/uri-list REMPLACE la liste entière des membres")
        void putReplacesTheWholeMembership() throws Exception {
            // Piège documenté : PUT n'ajoute pas, il remplace. Utilisé pour
            // rattacher une personne, il évince silencieusement tous les autres
            // membres de l'organisation. C'est POST qu'il faut appeler — voir
            // OrganizationService.addPerson côté front.
            String orgId = createOrganization("Orion Incorporated");
            attach(orgId, createPerson("evince@example.net"));
            String newcomer = createPerson("newcomer@example.net");

            mockMvc.perform(put("/organizations/" + orgId + "/persons")
                    .contentType("text/uri-list")
                    .content("http://localhost/persons/" + newcomer))
                    .andExpect(status().isNoContent());

            mockMvc.perform(get("/organizations/" + orgId + "/persons"))
                    .andExpect(jsonPath("$._embedded.persons.length()").value(1))
                    .andExpect(jsonPath("$._embedded.persons[0].email").value("newcomer@example.net"));
        }

        @Test
        @DisplayName("DELETE côté propriétaire détache la personne")
        void deleteOnTheOwningSideDetachesTheMember() throws Exception {
            String orgId = createOrganization("Orion Incorporated");
            String stays = createPerson("stays@example.net");
            String leaves = createPerson("leaves@example.net");
            attach(orgId, stays);
            attach(orgId, leaves);

            mockMvc.perform(delete("/organizations/" + orgId + "/persons/" + leaves))
                    .andExpect(status().isNoContent());

            mockMvc.perform(get("/organizations/" + orgId + "/persons"))
                    .andExpect(jsonPath("$._embedded.persons.length()").value(1))
                    .andExpect(jsonPath("$._embedded.persons[0].email").value("stays@example.net"));
        }

        @Test
        @DisplayName("DELETE côté inverse répond 204 mais ne détache rien")
        void deleteOnTheInverseSideIsSilentlyIgnored() throws Exception {
            // Person.organizations est le côté INVERSE (mappedBy) : il n'écrit
            // pas dans la table de jointure. Spring Data REST répond quand même
            // 204, donc un client ne voit aucune erreur — l'appartenance reste.
            // C'est pourquoi le front doit passer par l'URL côté organisation.
            String orgId = createOrganization("Orion Incorporated");
            String personId = createPerson("stubborn@example.net");
            attach(orgId, personId);

            mockMvc.perform(delete("/persons/" + personId + "/organizations/" + orgId))
                    .andExpect(status().isNoContent());

            mockMvc.perform(get("/organizations/" + orgId + "/persons"))
                    .andExpect(jsonPath("$._embedded.persons.length()").value(1))
                    .andExpect(jsonPath("$._embedded.persons[0].email").value("stubborn@example.net"));
        }
    }
}
