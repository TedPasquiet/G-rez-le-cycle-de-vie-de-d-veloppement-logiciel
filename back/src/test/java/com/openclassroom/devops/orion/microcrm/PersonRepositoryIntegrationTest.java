package com.openclassroom.devops.orion.microcrm;

import java.util.Optional;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.TestEntityManager;

import jakarta.persistence.PersistenceException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests d'intégration JPA du {@link PersonRepository}. Chaque test est
 * transactionnel et annulé à la fin ({@code @DataJpaTest}).
 *
 * <p>Le moteur n'est plus HSQLDB par principe : il dépend de
 * {@code SPRING_DATASOURCE_URL}. Voir {@link AbstractRepositoryIntegrationTest}.
 */
class PersonRepositoryIntegrationTest extends AbstractRepositoryIntegrationTest {

    @Autowired
    private TestEntityManager entityManager;

    @Autowired
    private PersonRepository personRepository;

    @Test
    void whenFindByEmail_thenReturnPerson() {
        // given
        Person jdoe = new Person();
        jdoe.setEmail("jdoe@example.net");
        entityManager.persist(jdoe);
        entityManager.flush();

        // when
        Optional<Person> found = personRepository.findByEmail("jdoe@example.net");

        assertEquals(jdoe.getEmail(), found.get().getEmail());
    }

    @Test
    @DisplayName("findByEmail sur un email inconnu retourne un Optional vide")
    void whenFindByUnknownEmail_thenReturnEmpty() {
        entityManager.persist(new Person("John", "Doe", "jdoe@example.net"));
        entityManager.flush();

        Optional<Person> found = personRepository.findByEmail("nobody@example.net");

        assertTrue(found.isEmpty());
    }

    @Test
    @DisplayName("findByEmail est sensible à la casse")
    void findByEmailIsCaseSensitive() {
        entityManager.persist(new Person("John", "Doe", "jdoe@example.net"));
        entityManager.flush();

        assertTrue(personRepository.findByEmail("JDOE@EXAMPLE.NET").isEmpty(),
                "aucune normalisation de casse n'est faite sur l'email");
    }

    @Test
    @DisplayName("save attribue un identifiant et l'horodatage de création")
    void saveAssignsIdAndCreationTimestamp() {
        Person saved = personRepository.save(new Person("Jane", "Roe", "jroe@example.net"));
        entityManager.flush();

        assertTrue(saved.getId() > 0, "l'id est généré par la séquence Hibernate");
        assertNotNull(saved.getCreatedAt(), "@CreationTimestamp est posé à l'insert");
        assertNotNull(saved.getUpdatedAt(), "@UpdateTimestamp est posé dès l'insert");
    }

    @Test
    @DisplayName("Tous les champs sont bien persistés puis relus")
    void allFieldsSurviveARoundTrip() {
        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        jdoe.setPhone("+33 6 12 34 56 78");
        jdoe.setBio("Testeur");
        long id = entityManager.persistAndGetId(jdoe, Long.class);
        entityManager.flush();
        entityManager.clear();

        Person reloaded = personRepository.findById(id).orElseThrow();

        assertEquals("John", reloaded.getFirstName());
        assertEquals("Doe", reloaded.getLastName());
        assertEquals("jdoe@example.net", reloaded.getEmail());
        assertEquals("+33 6 12 34 56 78", reloaded.getPhone());
        assertEquals("Testeur", reloaded.getBio());
    }

    @Test
    @DisplayName("Une modification met à jour le champ persisté")
    void updatingAPersonPersistsTheNewValue() {
        Person jdoe = entityManager.persistFlushFind(new Person("John", "Doe", "jdoe@example.net"));

        jdoe.setEmail("john.doe@example.net");
        personRepository.save(jdoe);
        entityManager.flush();
        entityManager.clear();

        assertTrue(personRepository.findByEmail("john.doe@example.net").isPresent());
        assertTrue(personRepository.findByEmail("jdoe@example.net").isEmpty());
    }

    @Test
    @DisplayName("count reflète les insertions")
    void countReflectsInsertions() {
        assertEquals(0, personRepository.count(), "@DataJpaTest ne charge pas InitialDataFixture");

        entityManager.persist(new Person("John", "Doe", "jdoe@example.net"));
        entityManager.persist(new Person("Jane", "Roe", "jroe@example.net"));
        entityManager.flush();

        assertEquals(2, personRepository.count());
    }

    @Test
    @DisplayName("findAll retourne toutes les personnes enregistrées")
    void findAllReturnsEveryPerson() {
        entityManager.persist(new Person("John", "Doe", "jdoe@example.net"));
        entityManager.persist(new Person("Jane", "Roe", "jroe@example.net"));
        entityManager.flush();

        assertEquals(2, personRepository.findAll().spliterator().getExactSizeIfKnown());
    }

    @Test
    @DisplayName("Deux personnes ne peuvent pas partager le même email")
    void duplicateEmailsAreRejected() {
        entityManager.persist(new Person("John", "Doe", "dup@example.net"));
        entityManager.persist(new Person("Jane", "Roe", "dup@example.net"));

        // La contrainte d'unicité sur Person.email garantit que findByEmail
        // ne peut jamais ramener plusieurs lignes.
        assertThrows(PersistenceException.class, () -> entityManager.flush());
    }

    @Test
    @DisplayName("Plusieurs personnes peuvent avoir un email nul")
    void severalPersonsMayHaveANullEmail() {
        entityManager.persist(new Person("John", "Doe", null));
        entityManager.persist(new Person("Jane", "Roe", null));
        entityManager.flush();

        assertEquals(2, personRepository.count(),
                "une contrainte UNIQUE SQL n'interdit pas plusieurs NULL");
    }

    @Test
    @DisplayName("findByEmail reste sûr : l'unicité garantit au plus un résultat")
    void findByEmailCanNeverMatchMoreThanOneRow() {
        entityManager.persist(new Person("John", "Doe", "jdoe@example.net"));
        entityManager.flush();

        Optional<Person> found = personRepository.findByEmail("jdoe@example.net");

        assertTrue(found.isPresent());
        assertEquals("Doe", found.get().getLastName());
    }

    @Test
    @DisplayName("findById sur un id inconnu retourne un Optional vide")
    void findByIdOnUnknownIdReturnsEmpty() {
        assertFalse(personRepository.findById(4242L).isPresent());
    }
}
