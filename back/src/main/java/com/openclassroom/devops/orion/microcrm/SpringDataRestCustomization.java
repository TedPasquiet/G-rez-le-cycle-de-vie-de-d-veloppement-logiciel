package com.openclassroom.devops.orion.microcrm;

import java.util.List;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.rest.core.config.RepositoryRestConfiguration;
import org.springframework.data.rest.webmvc.config.RepositoryRestConfigurer;
import org.springframework.web.servlet.config.annotation.CorsRegistry;

/**
 * Point unique de configuration CORS de l'API : les dépôts n'exposent pas de
 * {@code @CrossOrigin} qui contournerait ces règles.
 */
@Configuration
public class SpringDataRestCustomization implements RepositoryRestConfigurer {

    /**
     * Origines autorisées à appeler l'API, listées explicitement plutôt qu'en
     * joker : une valeur "*" laisserait n'importe quel site lire les données.
     * Surchargeable par environnement via MICROCRM_CORS_ALLOWED_ORIGINS.
     */
    private final List<String> allowedOrigins;

    public SpringDataRestCustomization(
            @Value("${microcrm.cors.allowed-origins}") List<String> allowedOrigins) {
        this.allowedOrigins = List.copyOf(allowedOrigins);
    }

    @Override
    public void configureRepositoryRestConfiguration(RepositoryRestConfiguration config, CorsRegistry cors) {
        config.exposeIdsFor(Person.class, Organization.class);
        cors.addMapping("/**")
                .allowedOrigins(allowedOrigins.toArray(String[]::new))
                .allowedMethods("GET", "POST", "PATCH", "DELETE")
                .exposedHeaders("Access-Control-Allow-Origin")
                .allowCredentials(false).maxAge(3600);
        RepositoryRestConfigurer.super.configureRepositoryRestConfiguration(config, cors);
    }
}
