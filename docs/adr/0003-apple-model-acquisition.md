# Confier les téléchargements Apple à URLSession

La bibliothèque Apple acquiert les modèles avec `URLSession` avant d’enregistrer les fichiers terminés auprès du moteur. Réutiliser directement le téléchargement du moteur aurait réduit le code spécifique à Apple, mais ne fournit pas la gestion des transferts en arrière-plan iOS et supprime les fichiers partiels lors d’une annulation. Le choix de `URLSession` permet d’intégrer l’arrière-plan et la reprise selon les possibilités du système et du serveur ; le moteur reste responsable du chargement et de l’inférence.

Les fichiers importés sont copiés dans le stockage géré par l’application. Supprimer un modèle géré ne supprime jamais son fichier d’origine. Les modèles de vision associent leurs poids au projecteur compatible.
