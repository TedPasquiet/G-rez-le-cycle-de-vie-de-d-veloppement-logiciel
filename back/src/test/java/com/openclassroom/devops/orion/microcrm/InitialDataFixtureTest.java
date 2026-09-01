package com.openclassroom.devops.orion.microcrm;

import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import ro.polak.springboot.datafixtures.DataFixtureSet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Jeu de données initial, testé sans base ni contexte Spring.
 *
 * <p>Ce composant ne s'exécute qu'une fois, au tout premier démarrage sur une
 * base vide : en pratique, personne ne le voit jamais tourner. C'est pourtant
 * lui qui décide si l'application redémarre avec des données ou en dupliquant
 * les précédentes, et la garde {@code canBeLoaded} est le seul rempart contre
 * la seconde situation.
 */
@ExtendWith(MockitoExtension.class)
class InitialDataFixtureTest {

    @Mock
    private PersonRepository personRepository;

    @Mock
    private OrganizationRepository organizationRepository;

    @InjectMocks
    private InitialDataFixture fixture;

    @Test
    @DisplayName("Le jeu est chargeable quand la table person est vide")
    void theFixtureLoadsOnAnEmptyDatabase() {
        when(personRepository.count()).thenReturn(0L);

        assertTrue(fixture.canBeLoaded());
    }

    @Test
    @DisplayName("Le jeu n'est pas rechargé si des personnes existent déjà")
    void theFixtureIsSkippedWhenDataAlreadyExists() {
        // Sans cette garde, chaque redémarrage ajouterait une organisation et
        // une personne de plus — et le second échouerait sur la contrainte
        // d'unicité de l'email.
        when(personRepository.count()).thenReturn(1L);

        assertFalse(fixture.canBeLoaded());
    }

    @Test
    @DisplayName("Le jeu appartient au groupe DICTIONARY")
    void theFixtureBelongsToTheDictionarySet() {
        assertSame(DataFixtureSet.DICTIONARY, fixture.getSet());
    }

    @Test
    @DisplayName("load enregistre une organisation portant la personne de démonstration")
    void loadPersistsAnOrganizationCarryingTheDemoPerson() {
        fixture.load();

        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<Organization>> captor = ArgumentCaptor.forClass(List.class);
        verify(organizationRepository).saveAll(captor.capture());

        List<Organization> saved = captor.getValue();
        assertEquals(1, saved.size());
        Organization orion = saved.get(0);
        assertEquals("Orion Incorporated", orion.getName());
        assertEquals(1, orion.getPersons().size());
        assertEquals("jdoe@example.net", orion.getPersons().get(0).getEmail());
        assertEquals("John", orion.getPersons().get(0).getFirstName());
    }

    @Test
    @DisplayName("load ne passe pas par le dépôt des personnes : la cascade s'en charge")
    void loadReliesOnTheCascadeRatherThanThePersonRepository() {
        // Documente la dépendance à CascadeType.PERSIST sur Organization.persons.
        // Si cette cascade disparaissait, le jeu initial n'insérerait plus aucune
        // personne — et ce test le signalerait avant le démarrage réel.
        fixture.load();

        verify(personRepository, never()).save(org.mockito.ArgumentMatchers.any());
        verify(personRepository, never()).saveAll(org.mockito.ArgumentMatchers.any());
    }
}
