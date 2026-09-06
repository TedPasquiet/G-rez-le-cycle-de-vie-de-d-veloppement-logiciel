package com.openclassroom.devops.orion.microcrm;

import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.autoconfigure.orm.jpa.TestEntityManager;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests d'intégration JPA du {@link OrganizationRepository} : persistance de
 * l'entité, cascade et table de jointure du many-to-many organisation ↔ personne.
 */
@DataJpaTest
class OrganizationRepositoryIntegrationTest {

    @Autowired
    private TestEntityManager entityManager;

    @Autowired
    private OrganizationRepository organizationRepository;

    @Autowired
    private PersonRepository personRepository;

    @Test
    @DisplayName("save attribue un identifiant et les horodatages")
    void saveAssignsIdAndTimestamps() {
        Organization org = new Organization();
        org.setName("Orion Incorporated");

        Organization saved = organizationRepository.save(org);
        entityManager.flush();

        assertTrue(saved.getId() > 0);
        assertEquals("Orion Incorporated", saved.getName());
        assertNotNull(saved.getCreatedAt());
        assertNotNull(saved.getUpdatedAt());
    }

    @Test
    @DisplayName("CascadeType.PERSIST enregistre les personnes rattachées à l'organisation")
    void savingAnOrganizationCascadesToItsPersons() {
        Organization org = new Organization();
        org.setName("Orion Incorporated");
        org.addPerson(new Person("John", "Doe", "jdoe@example.net"));

        organizationRepository.save(org);
        entityManager.flush();

        assertEquals(1, personRepository.count(),
                "la personne est insérée sans appel explicite au PersonRepository");
        assertTrue(personRepository.findByEmail("jdoe@example.net").isPresent());
    }

    @Test
    @DisplayName("La table de jointure survit à un aller-retour en base")
    void membershipSurvivesARoundTrip() {
        Organization org = new Organization();
        org.setName("Orion Incorporated");
        org.addPerson(new Person("John", "Doe", "jdoe@example.net"));
        org.addPerson(new Person("Jane", "Roe", "jroe@example.net"));

        long id = organizationRepository.save(org).getId();
        entityManager.flush();
        entityManager.clear();

        Organization reloaded = organizationRepository.findById(id).orElseThrow();
        List<Person> persons = reloaded.getPersons();

        assertEquals(2, persons.size());
        assertTrue(persons.stream().anyMatch(p -> "jdoe@example.net".equals(p.getEmail())));
        assertTrue(persons.stream().anyMatch(p -> "jroe@example.net".equals(p.getEmail())));
    }

    @Test
    @DisplayName("Une personne peut appartenir à plusieurs organisations")
    void aPersonCanBelongToSeveralOrganizations() {
        Person jdoe = entityManager.persistFlushFind(new Person("John", "Doe", "jdoe@example.net"));

        Organization orion = new Organization();
        orion.setName("Orion Incorporated");
        orion.addPerson(jdoe);

        Organization vega = new Organization();
        vega.setName("Vega Ltd");
        vega.addPerson(jdoe);

        long personId = jdoe.getId();
        organizationRepository.save(orion);
        organizationRepository.save(vega);
        entityManager.flush();
        entityManager.clear();

        Person reloaded = personRepository.findById(personId).orElseThrow();
        List<Organization> organizations = reloaded.getOrganizations();

        assertEquals(2, organizations.size(),
                "le côté inverse du many-to-many est alimenté par la table de jointure");
        assertTrue(organizations.stream().anyMatch(o -> "Orion Incorporated".equals(o.getName())));
        assertTrue(organizations.stream().anyMatch(o -> "Vega Ltd".equals(o.getName())));
        assertEquals(1, personRepository.count(), "une seule ligne person, pas de duplication");
    }

    @Test
    @DisplayName("removePerson retire l'appartenance sans supprimer la personne")
    void removePersonDetachesWithoutDeletingThePerson() {
        Organization org = new Organization();
        org.setName("Orion Incorporated");
        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        org.addPerson(jdoe);

        long id = organizationRepository.save(org).getId();
        entityManager.flush();

        Organization managed = organizationRepository.findById(id).orElseThrow();
        managed.removePerson(managed.getPersons().get(0));
        organizationRepository.save(managed);
        entityManager.flush();
        entityManager.clear();

        assertTrue(organizationRepository.findById(id).orElseThrow().getPersons().isEmpty(),
                "l'appartenance est rompue");
        assertEquals(1, personRepository.count(),
                "la personne existe toujours en base");
    }

    @Test
    @DisplayName("Une organisation sans membre est valide")
    void anEmptyOrganizationIsValid() {
        Organization org = new Organization();
        org.setName("Organisation vide");

        long id = organizationRepository.save(org).getId();
        entityManager.flush();
        entityManager.clear();

        Organization reloaded = organizationRepository.findById(id).orElseThrow();
        assertTrue(reloaded.getPersons().isEmpty());
        assertEquals(0, personRepository.count());
    }

    @Test
    @DisplayName("count reflète les insertions d'organisations")
    void countReflectsInsertions() {
        assertEquals(0, organizationRepository.count());

        Organization orion = new Organization();
        orion.setName("Orion Incorporated");
        Organization vega = new Organization();
        vega.setName("Vega Ltd");
        organizationRepository.saveAll(List.of(orion, vega));
        entityManager.flush();

        assertEquals(2, organizationRepository.count());
    }
}
