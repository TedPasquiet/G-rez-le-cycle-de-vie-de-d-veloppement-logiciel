package com.openclassroom.devops.orion.microcrm;

import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.autoconfigure.orm.jpa.TestEntityManager;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Suppression d'une personne : comportement du hook {@code @PreRemove}
 * ({@code Person.remoteFromOrganization}), qui détache la personne de toutes
 * ses organisations avant que la ligne ne parte.
 *
 * <p>C'est le seul endroit du modèle où du code métier s'exécute en dehors d'un
 * getter/setter, et le seul chemin qui reste silencieux tant qu'on ne supprime
 * rien : sans ces tests, une régression sur la table de jointure ne serait
 * visible qu'en production, au moment d'un DELETE /persons/{id}.
 */
@DataJpaTest
class PersonDeletionIntegrationTest {

    @Autowired
    private TestEntityManager entityManager;

    @Autowired
    private PersonRepository personRepository;

    @Autowired
    private OrganizationRepository organizationRepository;

    /** Persiste une organisation et ses membres, puis vide le contexte de persistance. */
    private long persistOrganizationWith(String name, Person... persons) {
        Organization org = new Organization();
        org.setName(name);
        for (Person person : persons) {
            org.addPerson(person);
        }
        long id = organizationRepository.save(org).getId();
        entityManager.flush();
        entityManager.clear();
        return id;
    }

    @Test
    @DisplayName("Supprimer une personne rompt son appartenance sans supprimer l'organisation")
    void deletingAPersonDetachesItFromItsOrganization() {
        long orgId = persistOrganizationWith("Orion Incorporated",
                new Person("John", "Doe", "jdoe@example.net"));
        long personId = personRepository.findByEmail("jdoe@example.net").orElseThrow().getId();

        personRepository.deleteById(personId);
        entityManager.flush();
        entityManager.clear();

        assertTrue(personRepository.findById(personId).isEmpty(), "la personne est supprimée");
        Organization org = organizationRepository.findById(orgId).orElseThrow();
        assertNotNull(org, "l'organisation survit à la suppression de son membre");
        assertTrue(org.getPersons().isEmpty(),
                "la ligne de la table de jointure est retirée par @PreRemove");
    }

    @Test
    @DisplayName("La suppression ne touche pas les autres membres de l'organisation")
    void deletingAPersonLeavesTheOtherMembersInPlace() {
        long orgId = persistOrganizationWith("Orion Incorporated",
                new Person("John", "Doe", "jdoe@example.net"),
                new Person("Jane", "Roe", "jroe@example.net"));
        long jdoeId = personRepository.findByEmail("jdoe@example.net").orElseThrow().getId();

        personRepository.deleteById(jdoeId);
        entityManager.flush();
        entityManager.clear();

        List<Person> remaining = organizationRepository.findById(orgId).orElseThrow().getPersons();
        assertEquals(1, remaining.size());
        assertEquals("jroe@example.net", remaining.get(0).getEmail());
        assertEquals(1, personRepository.count());
    }

    @Test
    @DisplayName("@PreRemove détache la personne de TOUTES ses organisations")
    void deletingAPersonDetachesItFromEveryOrganization() {
        Person jdoe = entityManager.persistFlushFind(new Person("John", "Doe", "jdoe@example.net"));
        long personId = jdoe.getId();
        long orionId = persistOrganizationWith("Orion Incorporated", jdoe);
        long vegaId = persistOrganizationWith("Vega Ltd",
                entityManager.find(Person.class, personId));

        personRepository.deleteById(personId);
        entityManager.flush();
        entityManager.clear();

        assertTrue(organizationRepository.findById(orionId).orElseThrow().getPersons().isEmpty());
        assertTrue(organizationRepository.findById(vegaId).orElseThrow().getPersons().isEmpty());
    }

    @Test
    @DisplayName("Supprimer une personne sans organisation ne lève pas d'erreur")
    void deletingAnUnaffiliatedPersonIsSafe() {
        // Chemin nominal du front : une personne créée via POST /persons n'est
        // rattachée à rien. Le hook itère alors sur une collection vide — et non
        // sur null, Hibernate initialisant toujours le côté inverse à la lecture.
        Person orphan = entityManager.persistFlushFind(new Person("Solo", "Player", "solo@example.net"));
        long personId = orphan.getId();
        entityManager.clear();

        personRepository.deleteById(personId);
        entityManager.flush();

        assertFalse(personRepository.findById(personId).isPresent());
    }

    @Test
    @DisplayName("Supprimer une organisation ne supprime pas ses membres")
    void deletingAnOrganizationKeepsItsPersons() {
        // CascadeType.ALL porte sur la persistance, pas sur l'orphelin : il n'y a
        // pas d'orphanRemoval, une personne reste donc en base sans rattachement.
        long orgId = persistOrganizationWith("Orion Incorporated",
                new Person("John", "Doe", "jdoe@example.net"));

        organizationRepository.deleteById(orgId);
        entityManager.flush();
        entityManager.clear();

        assertTrue(organizationRepository.findById(orgId).isEmpty());
        assertEquals(1, personRepository.count(), "la personne survit à son organisation");
    }
}
