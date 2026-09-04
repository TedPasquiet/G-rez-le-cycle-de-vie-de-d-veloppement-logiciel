package com.openclassroom.devops.orion.microcrm;

import java.net.URI;

import com.jayway.jsonpath.JsonPath;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Tests de lecture de la couche REST exposée automatiquement par Spring Data
 * REST : endpoints HAL, exposition des identifiants configurée dans
 * {@link SpringDataRestCustomization} et forme des charges utiles.
 *
 * <p>Les écritures sont dans {@link PersonRestLifecycleTest}, la politique CORS
 * dans {@link CorsPolicyTest}.
 */
@SpringBootTest
@AutoConfigureMockMvc
class PersonRestApiTest {

    /** Email de la personne du jeu initial ({@link InitialDataFixture}). */
    private static final String EMAIL_DU_JEU_INITIAL = "jdoe@example.net";

    /** Email de la seule personne que cette classe crée, et donc committe. */
    private static final String EMAIL_CREE_PAR_LA_CLASSE = "jroe-post@example.net";

    @Autowired
    private MockMvc mockMvc;

    /**
     * Identifiant de la personne du jeu initial, résolu par son email.
     *
     * <p>Il valait 1 en dur, ce qui n'est vrai que sur une base neuve : sur un
     * PostgreSQL partagé, les tests {@code @DataJpaTest} consomment
     * {@code person_seq} par blocs de 50 et l'identifiant dépend de l'ordre.
     */
    private String idDuJeuInitial() throws Exception {
        String corps = mockMvc.perform(get("/persons/search/findByEmail")
                .param("email", EMAIL_DU_JEU_INITIAL))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();
        // Le type est déclaré Object à dessein : JsonPath.read() est générique,
        // et String.valueOf() sur son résultat inféré compile vers la surcharge
        // char[] — un ClassCastException à l'exécution.
        Object id = JsonPath.parse(corps).read("$.id");
        return id.toString();
    }

    /**
     * Range derrière les tests qui écrivent.
     *
     * <p>La classe ne peut pas être {@code @Transactional} (le test du doublon
     * met la transaction PostgreSQL en échec) : ses écritures sont committées.
     * Sans ce ménage, la 2ᵉ exécution recevrait 409 au lieu de 201.
     */
    @AfterEach
    void supprimeLesLignesCommitteesParLesTests() throws Exception {
        MockHttpServletResponse recherche = mockMvc.perform(get("/persons/search/findByEmail")
                .param("email", EMAIL_CREE_PAR_LA_CLASSE))
                .andReturn().getResponse();
        if (recherche.getStatus() == 200) {
            Object id = JsonPath.parse(recherche.getContentAsString()).read("$.id");
            mockMvc.perform(delete("/persons/" + id)).andExpect(status().isNoContent());
        }
    }

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
        mockMvc.perform(get("/persons/" + idDuJeuInitial() + "/organizations"))
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
        mockMvc.perform(get("/persons/search/findByEmail").param("email", EMAIL_DU_JEU_INITIAL))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.email").value(EMAIL_DU_JEU_INITIAL));
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
                .andExpect(jsonPath("$.email").value(EMAIL_CREE_PAR_LA_CLASSE));

        mockMvc.perform(get("/persons/search/findByEmail").param("email", EMAIL_CREE_PAR_LA_CLASSE))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.lastName").value("Roe"));
    }

    @Test
    @DisplayName("Les horodatages sont exposés : le front les affiche")
    void timestampsAreExposedInPayloads() throws Exception {
        // Les gabarits person-details et organization-details passent createdAt
        // et updatedAt dans un DatePipe. Sans ces champs, la page afficherait
        // des cases vides sans qu'aucun test ne bronche.
        mockMvc.perform(get("/persons/" + idDuJeuInitial()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.createdAt").exists())
                .andExpect(jsonPath("$.updatedAt").exists());
    }

    @Test
    @DisplayName("Un email déjà pris retourne 409 et ne crée rien")
    void duplicateEmailIsRejectedWithConflict() throws Exception {
        // La contrainte d'unicité est portée par la base (Person.email est
        // @Column(unique = true)) : c'est le seul garde-fou, l'entité n'a
        // aucune validation applicative. On vérifie qu'elle remonte bien en
        // 409 au client, et pas en 500.
        long before = totalPersons();

        mockMvc.perform(post("/persons")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {"firstName":"Imposteur","lastName":"Doe","email":"jdoe@example.net"}
                        """))
                .andExpect(status().isConflict());

        org.junit.jupiter.api.Assertions.assertEquals(before, totalPersons(),
                "aucune ligne n'est insérée quand la contrainte rejette l'écriture");
    }

    private long totalPersons() throws Exception {
        String body = mockMvc.perform(get("/persons")).andReturn().getResponse().getContentAsString();
        java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("\"totalElements\"\\s*:\\s*(\\d+)").matcher(body);
        org.junit.jupiter.api.Assertions.assertTrue(m.find(), "totalElements absent de la réponse");
        return Long.parseLong(m.group(1));
    }

    @Test
    @DisplayName("GET sur une personne inexistante retourne 404")
    void getUnknownPersonReturnsNotFound() throws Exception {
        mockMvc.perform(get("/persons/999999"))
                .andExpect(status().isNotFound());
    }

}
