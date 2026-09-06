package com.openclassroom.devops.orion.microcrm;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.options;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Surcharge de l'allowlist CORS par la configuration, c'est-à-dire par la
 * variable d'environnement {@code MICROCRM_CORS_ALLOWED_ORIGINS} en production.
 *
 * <p>Sans ce test, la variabilisation n'est vérifiée nulle part : le paramètre
 * pourrait cesser d'être lu (valeur écrite en dur, mauvais nom de propriété)
 * sans qu'un seul test échoue. On ne s'en apercevrait qu'au déploiement, quand
 * le front d'un environnement se ferait refuser par l'API.
 *
 * <p>Le contexte est distinct de celui des autres tests — d'où une classe à
 * part plutôt qu'une classe imbriquée : Spring met en cache un contexte par
 * jeu de propriétés.
 */
@SpringBootTest(properties = {
    "microcrm.cors.allowed-origins=https://crm.example.org,https://admin.example.org"
})
@AutoConfigureMockMvc
class CorsAllowedOriginsOverrideTest {

    @Autowired
    private MockMvc mockMvc;

    private void expectPreflight(String origine, boolean autorisee) throws Exception {
        var requete = mockMvc.perform(options("/persons")
                .header("Origin", origine)
                .header("Access-Control-Request-Method", "GET"));
        if (autorisee) {
            requete.andExpect(status().isOk())
                    .andExpect(header().string("Access-Control-Allow-Origin", origine));
        } else {
            requete.andExpect(status().isForbidden());
        }
    }

    @Test
    @DisplayName("Les origines fournies par la configuration sont acceptées")
    void configuredOriginsAreAccepted() throws Exception {
        expectPreflight("https://crm.example.org", true);
    }

    @Test
    @DisplayName("La liste accepte plusieurs origines séparées par des virgules")
    void theListSupportsSeveralCommaSeparatedOrigins() throws Exception {
        // Le format compte : c'est celui qu'on écrira dans la variable
        // d'environnement du conteneur et dans les manifestes Kubernetes.
        expectPreflight("https://admin.example.org", true);
    }

    @Test
    @DisplayName("Le défaut d'application.properties ne s'applique plus une fois surchargé")
    void theBuiltInDefaultNoLongerApplies() throws Exception {
        // Le point important de la variabilisation : la valeur de développement
        // ne subsiste pas en production « au cas où ». Si elle survivait,
        // http://localhost:4200 resterait autorisé sur l'API de production.
        expectPreflight("http://localhost:4200", false);
    }
}
