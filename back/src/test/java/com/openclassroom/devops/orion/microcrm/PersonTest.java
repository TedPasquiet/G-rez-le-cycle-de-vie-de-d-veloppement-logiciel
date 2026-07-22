package com.openclassroom.devops.orion.microcrm;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

/**
 * Tests unitaires purs de l'entité {@link Person} : aucun contexte Spring,
 * aucune base de données. Ils s'exécutent en quelques millisecondes.
 */
class PersonTest {

    @Test
    @DisplayName("Le constructeur à 3 arguments renseigne prénom, nom et email")
    void constructorSetsNameAndEmail() {
        Person person = new Person("John", "Doe", "jdoe@example.net");

        assertEquals("John", person.getFirstName());
        assertEquals("Doe", person.getLastName());
        assertEquals("jdoe@example.net", person.getEmail());
    }

    @Test
    @DisplayName("Le constructeur à 3 arguments laisse les champs optionnels nuls")
    void constructorLeavesOptionalFieldsNull() {
        Person person = new Person("John", "Doe", "jdoe@example.net");

        assertNull(person.getPhone());
        assertNull(person.getBio());
    }

    @Test
    @DisplayName("Le constructeur par défaut ne renseigne aucun champ")
    void defaultConstructorLeavesEverythingNull() {
        Person person = new Person();

        assertNull(person.getFirstName());
        assertNull(person.getLastName());
        assertNull(person.getEmail());
        assertNull(person.getPhone());
        assertNull(person.getBio());
    }

    @Test
    @DisplayName("Une personne non persistée a l'id 0 et aucun horodatage")
    void transientPersonHasNoIdAndNoTimestamps() {
        Person person = new Person("John", "Doe", "jdoe@example.net");

        assertEquals(0L, person.getId());
        assertNull(person.getCreatedAt(), "createdAt est posé par Hibernate à l'insert");
        assertNull(person.getUpdatedAt(), "updatedAt est posé par Hibernate à l'update");
    }

    @Test
    @DisplayName("Les setters mettent à jour tous les champs modifiables")
    void settersUpdateEveryMutableField() {
        Person person = new Person();

        person.setFirstName("Jane");
        person.setLastName("Roe");
        person.setEmail("jroe@example.net");
        person.setPhone("+33 6 12 34 56 78");
        person.setBio("Développeuse");

        assertEquals("Jane", person.getFirstName());
        assertEquals("Roe", person.getLastName());
        assertEquals("jroe@example.net", person.getEmail());
        assertEquals("+33 6 12 34 56 78", person.getPhone());
        assertEquals("Développeuse", person.getBio());
    }

    @Test
    @DisplayName("Aucune validation n'est appliquée : email vide et nulls sont acceptés")
    void noValidationIsEnforcedOnFields() {
        // Documente l'état actuel : l'entité ne porte aucune contrainte
        // (@NotNull, @Email, @Column(unique=true)...). Voir la note du rapport.
        Person person = new Person(null, null, "");

        assertNull(person.getFirstName());
        assertEquals("", person.getEmail());
    }
}
