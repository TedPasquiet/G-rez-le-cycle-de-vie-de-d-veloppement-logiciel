# Cloisonnement réseau du namespace applicatif : un refus global du trafic
# entrant, puis réouverture des seuls flux dont l'architecture a besoin. Le
# modèle NetworkPolicy est additif — un pod voit l'union des règles qui le
# sélectionnent — donc l'ordre de lecture de ce fichier est aussi sa logique :
# ce qu'aucune règle n'autorise reste refusé, et ajouter un flux ne peut jamais
# en retirer un autre.
#
# ⚠️ Ces objets sont créés mais INERTES sur un minikube par défaut. L'application
# d'une NetworkPolicy appartient au CNI, pas à la ressource : le CNI par défaut
# de minikube ne l'implémente pas et ignore ces objets sans rien signaler —
# l'API server les accepte, `kubectl get networkpolicy` les affiche, et aucun
# paquet n'est filtré. Ce n'est pas un défaut de ce module ; l'état désiré est
# bien celui décrit ici. Mais il ne faut pas conclure d'un `terraform apply`
# réussi que le namespace est cloisonné. Les règles ne deviennent effectives que
# sur un CNI qui les implémente (`minikube start --cni=calico`, ou un cluster
# managé), et la seule preuve qui vaille est une tentative de connexion depuis
# un pod tiers.
#
# ⚠️ À VÉRIFIER le jour où un CNI appliquera réellement ces règles : le sort des
# sondes du kubelet sous ce `default-deny`. Le kubelet interroge les pods depuis
# le nœud, et aucune règle ci-dessous ne l'autorise. L'usage veut que le trafic
# issu du nœud échappe au filtrage, et c'est le comportement de Calico comme de
# Cilium — mais la spécification NetworkPolicy ne le garantit pas, elle ne dit
# rien de ce cas. C'est donc une hypothèse, pas un acquis. Symptôme si elle
# tombe : des pods qui restent Running sans jamais devenir Ready, startupProbe
# et readinessProbe en échec, et un déploiement qui expire alors que
# l'application va bien. Le correctif serait une règle `from` sur un `ip_block`
# couvrant le CIDR des nœuds — une valeur propre à chaque cluster, donc hors de
# ce module tant que le besoin n'est pas constaté.

resource "kubernetes_network_policy_v1" "default_deny_ingress" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "default-deny-ingress"
    namespace = var.namespace
    # Sans ces labels, ces trois policies échappent au recensement qui répond à
    # « qu'est-ce que Terraform possède ici ? » — et ce sont justement les
    # objets dont l'oubli se paie le plus cher : un `destroy` qui les emporte
    # rouvre le trafic sans que rien ne le signale.
    labels = var.labels
  }

  spec {
    # Sélecteur vide = tous les pods du namespace, y compris ceux qui n'y sont
    # pas encore. Énumérer back et front aurait laissé grand ouvert le premier
    # composant ajouté ensuite, et cet oubli n'aurait produit aucun signal.
    pod_selector {}

    # Uniquement "Ingress" : un type absent d'ici reste entièrement libre.
    # Restreindre l'egress casserait la résolution DNS dès la première requête —
    # CoreDNS vit dans kube-system, donc hors de portée d'une règle qui ne
    # parlerait que du namespace applicatif — pour un gain nul ici : le back
    # sert une base HSQLDB en mémoire et le front des fichiers statiques, aucun
    # des deux n'émet d'appel sortant qu'on chercherait à contenir.
    policy_types = ["Ingress"]

    # L'absence de bloc `ingress` est ce qui refuse. Un `ingress {}` vide mais
    # présent produirait exactement l'inverse : une règle sans `from` autorise
    # toutes les sources.
  }
}

# Les deux policies suivantes n'ouvrent qu'une source, le contrôleur d'Ingress,
# et c'est suffisant : le front est une application Angular, donc le navigateur
# charge le bundle depuis le pod front puis appelle l'API DEPUIS LE NAVIGATEUR,
# sur un hôte HTTP distinct (`api.microcrm.<env>`) routé par ce même contrôleur.
# Il n'existe aucun flux pod front → pod back. Une règle « front vers back »
# serait donc sans effet, et surtout mensongère pour qui lit ces policies pour
# comprendre l'architecture. Voir K8S.md §13 et §7.

resource "kubernetes_network_policy_v1" "allow_ingress_to_front" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "allow-ingress-nginx-to-front"
    namespace = var.namespace
    labels    = var.labels
  }

  spec {
    pod_selector {
      # Ce label est celui du `spec.selector.matchLabels` du Deployment, donc
      # immuable après création : s'y accrocher garantit que la policy et le
      # Deployment ne peuvent pas diverger sans qu'on recrée l'un des deux.
      match_labels = {
        "app.kubernetes.io/name" = "front"
      }
    }

    ingress {
      from {
        # `kubernetes.io/metadata.name` est posé par l'API server sur tout
        # namespace et vaut son nom : ce sélecteur n'impose donc aucun
        # étiquetage manuel du namespace du contrôleur, qui est créé par un
        # addon et qu'on ne veut pas avoir à modifier depuis Terraform.
        #
        # La granularité s'arrête au namespace, sans `pod_selector` : les labels
        # des pods d'ingress-nginx dépendent de son mode d'installation (addon
        # minikube, chart Helm, opérateur) et ne sont pas sous notre contrôle.
        # Un sélecteur trop fin y couperait le trafic à la première réinstallation.
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.ingress_controller_namespace
          }
        }
      }

      # Port du CONTENEUR, pas celui du Service : une NetworkPolicy s'évalue sur
      # le paquet tel qu'il arrive au pod, après que kube-proxy a traduit le
      # port du Service. Écrire ici le port du Service donnerait une policy
      # d'apparence correcte qui laisserait tomber tout le trafic.
      ports {
        port     = var.front_port
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_ingress_to_back" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "allow-ingress-nginx-to-back"
    namespace = var.namespace
    labels    = var.labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "back"
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.ingress_controller_namespace
          }
        }
      }

      # Le back est joignable de l'extérieur par un hôte dédié, et non par un
      # préfixe du front : c'est le navigateur qui l'appelle. Le trafic entrant
      # légitime vient donc du contrôleur, au même titre que celui du front.
      ports {
        port     = var.back_port
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}
