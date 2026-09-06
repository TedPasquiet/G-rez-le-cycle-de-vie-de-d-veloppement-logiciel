package com.openclassroom.devops.orion.microcrm;

import java.sql.Connection;
import java.sql.SQLException;

import javax.sql.DataSource;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Vérifie à quelle base parlent réellement les tests {@code @DataJpaTest}.
 *
 * <p>Une suite verte ne prouve rien ici : si l'on retire {@code replace = NONE}
 * du socle, les tests de dépôt repassent sur HSQLDB et continuent de passer
 * pendant que le pipeline annonce PostgreSQL. Ce test rend la régression visible.
 */
class DataJpaTestDatabaseTest extends AbstractRepositoryIntegrationTest {

    @Autowired
    private DataSource dataSource;

    @Test
    @DisplayName("La base des tests @DataJpaTest est bien celle qui est configurée")
    void dataJpaTestsTalkToTheConfiguredDatabase() throws SQLException {
        String urlDemandee = System.getenv("SPRING_DATASOURCE_URL");

        String urlEffective;
        try (Connection connection = dataSource.getConnection()) {
            urlEffective = connection.getMetaData().getURL();
        }

        if (urlDemandee == null || urlDemandee.isBlank()) {
            // Aucune base fournie : on doit retomber sur le comportement
            // d'origine, une HSQLDB en mémoire. Une URL de fichier ou de serveur
            // signifierait qu'un test écrit quelque part sur le poste.
            assertTrue(urlEffective.startsWith("jdbc:hsqldb:mem:"),
                    "sans SPRING_DATASOURCE_URL, la suite doit rester sur HSQLDB en mémoire, "
                            + "or elle utilise " + urlEffective);
        } else {
            assertEquals(urlDemandee, urlEffective,
                    "SPRING_DATASOURCE_URL est fournie mais les tests @DataJpaTest attaquent "
                            + "une autre base : la source de données a été remplacée par une base "
                            + "embarquée, et ces tests ne valident rien du moteur cible");
        }
    }
}
