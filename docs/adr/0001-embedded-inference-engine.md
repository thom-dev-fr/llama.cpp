# Extraire un moteur d’inférence embarquable commun

Le serveur et le CLI doivent devenir consommateurs d’un moteur C++ qui possède l’inférence et le cycle de vie multi-modèles, sans HTTP ni sous-processus nécessaires à l’exécution locale. Nous remplaçons donc le chemin local passant par le serveur plutôt que de le masquer derrière un wrapper ; ce drop migre les deux exécutables, tandis que l’exposition à Swift/iOS constitue une cible ultérieure.

Le moteur conserve les contrats JSON des différentes opérations existantes, via `nlohmann::json` pour ce drop, plutôt que d’imposer immédiatement un second modèle complet de données typées. Aucune stabilité ABI ni exposition directe de ces types à Swift n’est promise. Il possède ses threads, accepte des requêtes concurrentes et expose des objets requête avec lecture progressive, annulation coopérative et résultats opérationnels explicites ; plusieurs instances doivent pouvoir coexister.

## Conséquences

- Le serveur conserve HTTP, l’encodage SSE et la reprise des flux après déconnexion. Pour cette reprise, il garde la requête vivante et continue de la lire.
- Le moteur produit les appels d’outils mais ne les exécute pas. Les outils exécutés, MCP et l’UI restent hors du moteur.
- La configuration publique du moteur n’expose pas `common_params`. Les pièces jointes binaires peuvent accompagner les requêtes JSON indépendamment du multipart HTTP.
- L’acquisition réseau est un module optionnel partagé ; le socle local doit pouvoir être compilé sans HTTP.
- L’éviction automatique ne touche pas les modèles utilisés. Les attentes et files d’événements sont bornées ; un consommateur saturé provoque une erreur de sa requête plutôt qu’un blocage global ou une perte silencieuse de fragments.
- Ces bornes sont configurables par instance. Le serveur HTTP conserve la sémantique upstream (pas de limite d’admission, de file ni de taille propre au moteur) : une ré-architecture ne change pas le comportement observable du serveur (décision du 29 septembre 2026).
- Détruire une requête demande son annulation. Arrêter le moteur annule ses travaux, réveille ses lecteurs et attend ses threads, sans garantie d’interruption immédiate d’un calcul GPU.
- L’absence de sous-processus supprime leur isolation des pannes natives, leur terminaison forcée et leurs véritables codes de sortie. Les champs historiques correspondants seront adaptés et documentés côté serveur ; les erreurs de chargement/réveil récupérables deviennent des résultats explicites, sans promesse de rendre récupérables les erreurs fatales des backends.
- Le déchargement explicite ferme les admissions pour le modèle, annule ses travaux et attend leur arrêt avant de libérer ses ressources. Il se distingue de l’éviction automatique limitée aux modèles inactifs.
- Les limites de ressources s’appliquent par moteur et comptent les chargements en cours. Elles ne garantissent ni un budget mémoire CPU/GPU exact ni un arbitrage global entre moteurs.
- Le catalogue provient de modèles ou de sources configurés explicitement, sans découverte implicite ni écriture persistante implicite. Sa lecture, ses événements d’état/progression et les statistiques nécessaires au serveur sont accessibles indépendamment d’HTTP.
- L’historique conversationnel et l’orchestration des tours restent chez l’appelant ; les caches KV et slots ne constituent pas une mémoire conversationnelle implicite.
