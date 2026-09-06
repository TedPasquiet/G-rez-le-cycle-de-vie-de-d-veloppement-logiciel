package com.openclassroom.devops.orion.microcrm;

import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.autoconfigure.orm.jpa.TestEntityManager;

/**
 * Socle commun des tests d'intégration JPA (couche dépôt).
 *
 * <p>{@code replace = NONE} est indispensable : sans lui, {@code @DataJpaTest}
 * substitue une base embarquée et ces classes resteraient sur HSQLDB pendant que
 * le reste de la suite vise PostgreSQL — vertes, mais ne validant plus le moteur
 * cible. Sans base fournie, le comportement d'origine est intact.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
abstract class AbstractRepositoryIntegrationTest {

    @Autowired
    private PersonRepository personsToClear;

    @Autowired
    private OrganizationRepository organizationsToClear;

    @Autowired
    private TestEntityManager entityManagerToFlush;

    /**
     * Garantit que chaque test de dépôt part de tables vides.
     *
     * <p>Ces classes comptent des lignes et se supposent seules en base : sur un
     * PostgreSQL partagé, le jeu initial committé par les {@code @SpringBootTest}
     * les ferait échouer. Le nettoyage vit dans la transaction du test, annulée
     * ensuite. Les organisations d'abord, côté propriétaire du many-to-many.
     */
    @BeforeEach
    void startFromEmptyTables() {
        organizationsToClear.deleteAll();
        personsToClear.deleteAll();
        // Dans un même flush, Hibernate exécute TOUJOURS les INSERT avant les
        // DELETE : sans ce flush explicite, les insertions du test partiraient
        // avant la suppression du jeu initial et violeraient l'unicité de l'email.
        entityManagerToFlush.flush();
        entityManagerToFlush.clear();
    }
}
