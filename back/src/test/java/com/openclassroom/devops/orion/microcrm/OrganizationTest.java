package com.openclassroom.devops.orion.microcrm;

import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests unitaires purs de {@link Organization}, en particulier la gestion
 * paresseuse de la collection {@code persons} (côté propriétaire du many-to-many).
 */
class OrganizationTest {

    @Test
    @DisplayName("Une organisation neuve a une collection vide, jamais nulle")
    void aNewOrganizationHasAnEmptyCollection() {
        // Contrat exigé par Spring Data REST : POST /organizations/{id}/persons
        // ajoute directement dans cette collection, sans passer par addPerson.
        // Une valeur nulle y produirait une NullPointerException (HTTP 500).
        Organization org = new Organization();

        assertNotNull(org.getPersons());
        assertTrue(org.getPersons().isEmpty());
    }

    @Test
    @DisplayName("addPerson ajoute à la collection existante")
    void addPersonAppendsToTheCollection() {
        Organization org = new Organization();

        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        List<Person> persons = org.addPerson(jdoe);

        assertNotNull(persons);
        assertEquals(1, persons.size());
        assertSame(jdoe, persons.get(0));
    }

    @Test
    @DisplayName("addPerson réinitialise la collection si setPersons(null) l'a effacée")
    void addPersonRecoversFromANullCollection() {
        // setPersons est public : rien n'empêche un appelant d'y passer null.
        // Le garde-fou de addPerson reste donc utile après l'initialisation
        // du champ à la construction.
        Organization org = new Organization();
        org.setPersons(null);

        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        List<Person> persons = org.addPerson(jdoe);

        assertNotNull(persons);
        assertEquals(1, persons.size());
        assertSame(jdoe, persons.get(0));
    }

    @Test
    @DisplayName("addPerson retourne la collection interne, pas une copie")
    void addPersonReturnsTheBackingCollection() {
        Organization org = new Organization();

        List<Person> returned = org.addPerson(new Person("John", "Doe", "jdoe@example.net"));

        assertSame(org.getPersons(), returned);
    }

    @Test
    @DisplayName("addPerson conserve l'ordre d'insertion et accepte les doublons")
    void addPersonKeepsInsertionOrderAndAllowsDuplicates() {
        Organization org = new Organization();
        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        Person jroe = new Person("Jane", "Roe", "jroe@example.net");

        org.addPerson(jdoe);
        org.addPerson(jroe);
        org.addPerson(jdoe);

        List<Person> persons = org.getPersons();
        assertEquals(3, persons.size(), "aucune déduplication : c'est une List, pas un Set");
        assertSame(jdoe, persons.get(0));
        assertSame(jroe, persons.get(1));
        assertSame(jdoe, persons.get(2));
    }

    @Test
    @DisplayName("removePerson retire la personne présente")
    void removePersonRemovesAMember() {
        Organization org = new Organization();
        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        Person jroe = new Person("Jane", "Roe", "jroe@example.net");
        org.addPerson(jdoe);
        org.addPerson(jroe);

        List<Person> persons = org.removePerson(jdoe);

        assertEquals(1, persons.size());
        assertSame(jroe, persons.get(0));
    }

    @Test
    @DisplayName("removePerson sur une collection nulle l'initialise sans lever d'erreur")
    void removePersonOnNullCollectionIsSafe() {
        Organization org = new Organization();
        org.setPersons(null);

        List<Person> persons = org.removePerson(new Person("John", "Doe", "jdoe@example.net"));

        assertNotNull(persons);
        assertTrue(persons.isEmpty());
    }

    @Test
    @DisplayName("removePerson d'une personne absente ne change rien")
    void removePersonIgnoresUnknownMember() {
        Organization org = new Organization();
        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        org.addPerson(jdoe);

        List<Person> persons = org.removePerson(new Person("Jane", "Roe", "jroe@example.net"));

        assertEquals(1, persons.size(), "Person n'implémente pas equals : comparaison par référence");
        assertSame(jdoe, persons.get(0));
    }

    @Test
    @DisplayName("removePerson ne retire qu'une occurrence en cas de doublon")
    void removePersonRemovesASingleOccurrence() {
        Organization org = new Organization();
        Person jdoe = new Person("John", "Doe", "jdoe@example.net");
        org.addPerson(jdoe);
        org.addPerson(jdoe);

        org.removePerson(jdoe);

        assertEquals(1, org.getPersons().size());
    }

    @Test
    @DisplayName("setPersons remplace intégralement la collection")
    void setPersonsReplacesTheCollection() {
        Organization org = new Organization();
        org.addPerson(new Person("John", "Doe", "jdoe@example.net"));

        List<Person> replacement = new ArrayList<>();
        replacement.add(new Person("Jane", "Roe", "jroe@example.net"));
        org.setPersons(replacement);

        assertSame(replacement, org.getPersons());
        assertEquals(1, org.getPersons().size());
        assertEquals("jroe@example.net", org.getPersons().get(0).getEmail());
    }

    @Test
    @DisplayName("Le nom est modifiable et une organisation non persistée n'a pas d'horodatage")
    void nameIsMutableAndTransientOrgHasNoTimestamps() {
        Organization org = new Organization();
        org.setName("Orion Incorporated");

        assertEquals("Orion Incorporated", org.getName());
        assertEquals(0L, org.getId());
        assertNull(org.getCreatedAt());
        assertNull(org.getUpdatedAt());
    }
}
