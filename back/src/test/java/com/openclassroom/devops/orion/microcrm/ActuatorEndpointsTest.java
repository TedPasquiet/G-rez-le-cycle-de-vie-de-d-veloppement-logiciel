package com.openclassroom.devops.orion.microcrm;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Endpoints Actuator, tels que les consomment les sondes Kubernetes.
 *
 * <p>Ces URL ne sont écrites nulle part dans le code Java : elles sont produites
 * par la configuration d'{@code application.properties} et référencées dans les
 * manifestes ({@code k8s/}, {@code helm/}). Une propriété modifiée par
 * inadvertance les ferait disparaître sans casser la compilation — et le
 * symptôme serait un pod qui ne passe jamais {@code Ready} en production.
 *
 * <p>Le second volet est la surface exposée : {@code /actuator/env} et
 * {@code /actuator/heapdump} divulgueraient la configuration et la mémoire du
 * processus à un appelant anonyme, l'API n'ayant aucune authentification.
 */
@SpringBootTest
@AutoConfigureMockMvc
class ActuatorEndpointsTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("/actuator/health répond UP")
    void healthReportsUp() throws Exception {
        mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @ParameterizedTest(name = "{0} répond UP")
    @ValueSource(strings = { "/actuator/health/liveness", "/actuator/health/readiness" })
    @DisplayName("Les sondes liveness et readiness de Kubernetes sont publiées")
    void probesAreExposed(String url) throws Exception {
        // management.endpoint.health.probes.enabled=true : sans ce réglage, ces
        // deux URL n'existent qu'en environnement Kubernetes détecté, donc pas
        // en local ni en CI — et la différence ne se verrait qu'au déploiement.
        mockMvc.perform(get(url))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    @DisplayName("/actuator/health ne divulgue pas l'état des composants internes")
    void healthDoesNotLeakInternalDetails() throws Exception {
        // show-details=never : l'endpoint est joignable sans authentification.
        // Le détail contiendrait l'URL de la base de données et l'espace disque.
        mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.components").doesNotExist())
                .andExpect(jsonPath("$.details").doesNotExist());
    }

    @ParameterizedTest(name = "{0} n'est pas exposé")
    @ValueSource(strings = {
        "/actuator/env",
        "/actuator/beans",
        "/actuator/configprops",
        "/actuator/heapdump",
        "/actuator/mappings",
        "/actuator/loggers",
    })
    @DisplayName("Aucun endpoint sensible n'est exposé sur le web")
    void sensitiveEndpointsAreNotExposed(String url) throws Exception {
        // management.endpoints.web.exposure.include=health. Élargir cette liste
        // doit rester un choix visible en revue : ce test transforme un tel
        // changement en échec de build plutôt qu'en fuite silencieuse.
        mockMvc.perform(get(url)).andExpect(status().isNotFound());
    }
}
