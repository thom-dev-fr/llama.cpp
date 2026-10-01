# Partager explicitement les ressources d’inférence entre sessions Apple

La bibliothèque Apple utilise un runtime créé explicitement par l’application et partagé entre ses sessions Foundation Models. Ce runtime mutualise les poids des modèles et borne les générations simultanées, tandis que chaque session conserve une conversation indépendante. Un moteur dédié à chaque session aurait simplifié leur isolation mais dupliqué les ressources des modèles ; un singleton implicite aurait masqué leur propriété et leur durée de vie.

Le partage des ressources ne transfère pas la propriété des conversations au moteur et n’autorise pas le mélange de leurs historiques. Le déchargement explicite d’un modèle annule les générations de toutes les sessions qui l’utilisent et conserve leurs historiques. Une demande ultérieure peut recharger le modèle sans reprendre la génération interrompue.

La limite de modèles résidents est configurable, avec un modèle par défaut dans la démo. L’éviction automatique ne concerne que les modèles inactifs. L’admission utilise une file bornée, annulable et observable ; sa saturation produit une erreur explicite. Une conversation inactive ne réserve pas de place de génération.
