package com.openclassroom.devops.orion.microcrm;

import org.springframework.data.repository.PagingAndSortingRepository;
import org.springframework.data.repository.query.Param;

import java.util.Optional;

import org.springframework.data.repository.CrudRepository;
import org.springframework.data.rest.core.annotation.RepositoryRestResource;

// La configuration CORS est centralisée dans SpringDataRestCustomization :
// pas de @CrossOrigin ici, qui dupliquerait la règle avec des valeurs plus
// permissives (toutes origines, toutes méthodes) que la politique globale.
@RepositoryRestResource
public interface PersonRepository extends PagingAndSortingRepository<Person, Long>, CrudRepository<Person, Long> {
    Optional<Person> findByEmail(@Param("email") String email);
}
