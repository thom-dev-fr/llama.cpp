# Inférence embarquée

Vocabulaire du moteur d’inférence commun aux applications, notamment au serveur et au CLI.

## Language

**Moteur d’inférence** :
Module qui prend en charge les requêtes d’inférence et le cycle de vie des modèles sélectionnés. Le serveur et le CLI en sont des consommateurs.
_Avoid_ : Serveur embarqué

**Catalogue de modèles** :
Ensemble des modèles connus du moteur et sélectionnables par identifiant. Un modèle présent au catalogue n’est pas nécessairement chargé.

**Modèle chargé** :
Modèle dont les ressources nécessaires à l’inférence sont actuellement résidentes. Plusieurs modèles peuvent être chargés simultanément dans les limites de la politique de ressources.
_Avoid_ : Modèle disponible (ambigu entre présence au catalogue et chargement)

**Éviction d’un modèle** :
Déchargement automatique d’un modèle inactif afin de libérer des ressources pour un autre modèle, sans le retirer du catalogue. Un modèle utilisé par une requête en cours n’est pas éligible à l’éviction.

**Déchargement explicite** :
Demande de libération des ressources d’un modèle, distincte de son retrait du catalogue. Elle ferme l’admission de nouvelles requêtes pour ce modèle et annule ses travaux avant de libérer ses ressources.
_Avoid_ : Éviction automatique

**Conversation** :
Historique d’échanges pouvant inclure des messages, des appels d’outils et leurs résultats. L’appelant en est responsable et fournit le contexte nécessaire à chaque requête d’inférence.
_Avoid_ : Slot, cache KV (ressources d’inférence, pas historiques conversationnels)

**Appel d’outil** :
Demande produite par le modèle désignant un outil et les arguments proposés pour son invocation. Produire un appel d’outil ne signifie pas exécuter cet outil.
_Avoid_ : Exécution d’outil

**Exécution d’outil** :
Action réalisée par l’hôte en réponse à un appel d’outil. Elle ne relève pas du moteur d’inférence.
_Avoid_ : Appel d’outil

**Occupation du contexte** :
Quantité de tokens occupant la fenêtre de contexte utilisée pour une inférence, rapportée à sa capacité. Elle se distingue de la consommation cumulée de tokens au cours d’une conversation.
_Avoid_ : Avancement du contexte, consommation cumulée

**Progression du traitement du prompt** :
Part du prompt déjà traitée pour préparer la génération d’une réponse. Elle se distingue de l’occupation du contexte et de la progression de la génération.
_Avoid_ : Avancement du contexte
