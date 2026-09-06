package com.openclassroom.devops.orion.microcrm;

import java.util.ArrayList;
import java.time.Instant;
import java.util.List;

import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import jakarta.persistence.CascadeType;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.ManyToMany;

@Entity
public class Organization {

  @Id
  @GeneratedValue(strategy = GenerationType.AUTO)
  private long id;

  public long getId() {
    return id;
  }

  // Pas de CascadeType.ALL ici : REMOVE se propagerait de l'organisation vers
  // ses membres, alors qu'une personne existe indépendamment et peut appartenir
  // à plusieurs organisations. Concrètement, la cascade faisait échouer
  // DELETE /organizations/{id} en HTTP 500 (ConcurrentModificationException) :
  // Hibernate parcourait `persons` pour propager la suppression pendant que le
  // hook @PreRemove de Person retirait chaque membre de cette même liste.
  // PERSIST et MERGE suffisent au besoin réel : enregistrer une organisation
  // enregistre les personnes qu'on vient de lui rattacher.
  // Voir PersonDeletionIntegrationTest et OrganizationRestApiTest.
  // Initialisée dès la construction, et non paresseusement dans addPerson :
  // Spring Data REST ajoute directement dans la collection quand le front
  // rattache une personne (POST /organizations/{id}/persons), sans passer par
  // addPerson. Sur une organisation encore vide la collection valait null, et
  // l'appel partait en NullPointerException — HTTP 500 côté navigateur.
  // Voir OrganizationRestApiTest.AssociationEndpoints.
  @ManyToMany(cascade = { CascadeType.PERSIST, CascadeType.MERGE })
  private List<Person> persons = new ArrayList<Person>();

  public List<Person> addPerson(Person person) {
    if (this.persons == null) {
      this.persons = new ArrayList<Person>();
    }
    this.persons.add(person);
    return this.persons;
  }

  public List<Person> removePerson(Person person) {
    if (this.persons == null) {
      this.persons = new ArrayList<Person>();
    }
    this.persons.remove(person);
    return this.persons;
  }

  public List<Person> getPersons() {
    return persons;
  }

  public void setPersons(List<Person> persons) {
    this.persons = persons;
  }

  private String name;

  public String getName() {
    return name;
  }

  public void setName(String name) {
    this.name = name;
  }

  @CreationTimestamp
  private Instant createdAt;

  @UpdateTimestamp
  private Instant updatedAt;

  public Instant getCreatedAt() {
    return createdAt;
  }

  public Instant getUpdatedAt() {
    return updatedAt;
  }


}
