# Adaptateur Apple LanguageModel

Conception soumise à confirmation finale. Ce document distingue les décisions confirmées des propositions finales. L’avancement de l’implémentation et ses preuves sont suivis dans [le rapport](apple-language-model-report.md).

Le [plan d’implémentation transmissible à l’agent](apple-language-model-plan.md) décrit les étapes, les fichiers proposés, les dépendances et les critères de sortie. Il a été préparé à la demande de l’utilisateur ; les derniers réglages proposés ci-dessous y restent identifiés comme hypothèses réversibles.

## Périmètre confirmé

- Bibliothèque Swift réutilisable implémentant le protocole Apple `LanguageModel`, exploitant le nouveau moteur d’inférence embarqué de llama.cpp.
- Application de démonstration SwiftUI dans `examples`, consommatrice de cette bibliothèque.
- iOS 27 et macOS 27 minimum.
- Téléchargement de modèles, cycle de vie du chargement, réponses en streaming et appels d’outils.
- Deux indicateurs distincts : occupation du contexte et progression du traitement du prompt.
- Objectif de couverture : toutes les capacités de Foundation Models exploitables avec llama.cpp ; la matrice précise reste à établir, sans restriction initiale au texte.
- Runtime explicitement créé par l’application et partagé entre sessions, mutualisation des poids, conversations indépendantes et concurrence bornée.
- Saturation du contexte : erreur explicite, sans suppression ni résumé automatique de l’historique.
- Démo : petit catalogue de modèles validés et import de fichiers GGUF locaux.
- Distribution : Swift Package Manager avec XCFramework construit depuis ce dépôt et procédure de reconstruction reproductible.
- Nouvel exemple dédié à Foundation Models ; conservation de `examples/llama.swiftui`.
- Extensions ciblées et compatibles de l’API du moteur autorisées pour satisfaire le contrat de l’adaptateur, avec tests adaptés.
- Une demande d’inférence charge automatiquement un modèle déjà présent localement si nécessaire ; un chargement explicite reste disponible. Le téléchargement nécessite une action explicite.
- Un déchargement explicite annule les générations de toutes les sessions utilisant ce modèle, libère les ressources et conserve leurs historiques. Une génération interrompue ne reprend pas automatiquement ; un nouvel envoi peut recharger le modèle.
- Nombre de modèles résidents configurable ; un seul par défaut dans la démo. L’éviction automatique concerne uniquement les modèles inactifs.
- Démo : modèles téléchargés et réglages persistants ; conversations en mémoire, sans restauration après fermeture dans cette première version.
- Une option ou contrainte Apple sans traduction fidèle produit une erreur explicite et descriptive ; aucune approximation ni contrainte ignorée silencieusement. Les capacités annoncées et leurs combinaisons nécessitent des tests de conformité.
- Admission : file d’attente bornée, annulable et observable ; erreur explicite lorsque la file est pleine. Une conversation inactive ne réserve pas de place de génération.
- Téléchargements Apple via `URLSession`, avec arrière-plan et reprise des transferts interrompus, puis enregistrement des fichiers terminés auprès du moteur. Le moteur conserve le chargement et l’inférence.
- Import local : copie gérée dans le stockage de l’application, avec association du projecteur compatible pour la vision. La suppression depuis la démo retire la copie gérée, jamais le fichier d’origine.
- Démo : chat avec images, raisonnement affichable séparément, appels et résultats d’outils visibles, scénario de génération structurée `@Generable`.
- Deux outils locaux déterministes illustrent la boucle complète : calcul et consultation d’un petit catalogue fictif, sans service externe.
- Après annulation ou erreur, la démo conserve le fragment visible marqué « interrompu », mais le contexte repart du dernier tour complet. « Réessayer » soumet de nouveau la demande, sans reprise automatique du décodage.
- Au passage en arrière-plan iOS, annulation de la génération et demande d’annulation des travaux associés, sans reprise automatique au retour ; les téléchargements peuvent continuer. Sur macOS, réduire la fenêtre ou changer d’application n’interrompt pas la génération.
- Sélectionner un autre modèle dans la démo démarre une nouvelle conversation ; l’ancienne reste consultable pendant la session de l’app. La bibliothèque permet de fournir explicitement un historique compatible.

Le retour à un transcript antérieur ne défait pas les effets d’un outil déjà exécuté. L’annulation des outils et des calculs natifs est coopérative ; elle ne garantit pas un arrêt instantané. La démo utilise des outils locaux sans effets externes.

## Matrice de faisabilité constatée

Le SDK installé (Xcode 27A266a) expose quatre capacités déclarables : `guidedGeneration`, `toolCalling`, `reasoning` et `vision`, en complément du texte et du streaming. La couverture visée dépend des possibilités du modèle et de son template ; elle ne signifie pas que chaque modèle possède toutes les capacités.

| Surface Apple | Support moteur et travail restant |
| --- | --- |
| Texte et streaming | Chat et deltas existants ; traduction vers le canal Apple. |
| Génération structurée | Schéma JSON vers grammaire existant ; audit des contraintes Apple et des combinaisons avec outils requis. |
| Outils | Définitions, choix et arguments fragmentés existants ; traduction vers les outils orchestrés par Foundation Models. |
| Raisonnement | Sortie distincte existante ; correspondance des niveaux d’effort dépendante du modèle/template. |
| Vision | Images et projecteur compatibles via le moteur ; conversion des pièces jointes Apple et acquisition du projecteur à intégrer. |
| Options de génération | Paramètres usuels présents ; audit de la stratégie de sampling et de la seed Apple 64 bits face à la seed moteur 32 bits requis. |
| Usage et contexte | Compteurs disponibles ; métriques par requête et capacité effective à exposer sans confondre usage cumulé et occupation. |

L’audio et les embeddings ne sont pas des surfaces natives du protocole dans ce SDK. Leur présence dans le moteur n’établit pas un support via `LanguageModel`.

Pour l’erreur de saturation, désactiver le context shift ne suffit pas : pendant la génération, le chemin chat assimile actuellement une fenêtre épuisée à une limite de tokens générés. Une distinction explicite doit être exposée par le moteur.

## Contraintes constatées

- Le moteur expose actuellement une interface C++ ; le pont Swift reste à concevoir.
- Le moteur produit les appels d’outils, mais leur exécution appartient à l’hôte ; l’historique conversationnel reste également chez l’appelant (voir `../adr/0001-embedded-inference-engine.md`).
- Le SDK Xcode 27 installé expose `LanguageModel` et `LanguageModelExecutor`. Foundation Models orchestre les outils de la session.
- `LanguageModelSession.usage` est une consommation cumulée, pas une mesure de l’occupation actuelle du contexte.

## Propositions finales à confirmer

- Démo : une génération active et quatre demandes en attente au maximum ; limites configurables dans la bibliothèque. Les tests couvrent également deux générations simultanées. Les slots sont des ressources temporaires, pas des identifiants persistants de conversation.
- Premier profil de catalogue : Qwen3.5-2B Q4_K_M avec son projecteur compatible, déjà présent localement, à qualifier de bout en bout avec l’adaptateur. Les références de téléchargement et révisions seront figées lors de cette qualification. Les imports locaux n’obtiennent aucune capacité avancée sur la seule base de leur nom ; les capacités nécessitent des métadonnées fiables et une compatibilité vérifiée.
- Taille de contexte et réglages mémoire définis par profil modèle/appareil mesuré. Aucun budget mémoire n’est déduit de la seule taille disque des poids.
- Occupation : métrique de la requête active rapportée à la capacité effective fournie par le moteur, incluant le coût des outils et des images. En dehors d’une requête, la dernière mesure est identifiée comme telle ; elle ne prétend pas décrire un cache encore résident. La progression du traitement du prompt est un indicateur séparé. Une mesure indisponible n’est pas affichée comme zéro.
- Validation macOS native sur OS 27 requise pour déclarer la prise en charge entièrement validée ; tant que cette cible manque, la livraison est explicitement identifiée comme compilée mais non validée à l’exécution sur macOS 27.

La reprise réseau dépend des possibilités du serveur et des données de reprise conservées par le système ; le choix de `URLSession` ne garantit pas une reprise à l’octet près dans tous les cas.

## Organisation proposée de l’implémentation

1. Ajouter au moteur les informations manquantes, notamment la distinction entre contexte plein et limite de génération, et un pont vers Swift dont les détails C++ restent internes.
2. Construire le package Swift et le XCFramework reproductible ; implémenter runtime partagé, acquisition, import, cycle de vie et observation des états.
3. Implémenter `LanguageModel` et son executor : traduction du transcript, options, schémas, images, outils, raisonnement, streaming et erreurs ; laisser Foundation Models orchestrer les outils.
4. Ajouter la démo SwiftUI et ses scénarios, puis qualifier modèles et profils mémoire sur les cibles disponibles.

## Critères de validation proposés

- Compilation du package, du XCFramework et de la démo pour iOS 27 et macOS 27.
- Tests déterministes des conversions, des événements streamés, des schémas supportés/refusés, des erreurs et de l’annulation ; vérification du transcript réellement soumis après interruption.
- Intégration avec un modèle réel : texte, génération structurée streamée, boucle d’outil complète, raisonnement séparé, image avec projecteur et combinaisons de capacités annoncées.
- Deux sessions intercalées et simultanées : historiques indépendants, mutualisation des poids, file bornée et annulation sans contamination.
- Saturation avant et pendant génération : erreur explicite distincte d’un budget de sortie atteint, sans décalage silencieux du contexte.
- Téléchargement interrompu/repris ou redémarré proprement, passage en arrière-plan, import/suppression sans toucher à l’original, chargement automatique et déchargement en cours de génération.
- Mesures sur appareil : mémoire, premier token, débit et délai d’annulation. Les résultats sur simulateur ne remplacent pas la validation mémoire sur iPhone.

### Environnement constaté au 1er octobre 2026

Xcode 27 est installé avec un simulateur iOS 27 disponible. Un iPhone 16 Pro Max appairé est détecté ; le déploiement reste à vérifier selon la signature. Le Mac M1 Pro dispose de 16 Gio mais exécute macOS 26.7 : la compilation avec le SDK 27 est possible, pas l’exécution native de cet adaptateur nécessitant macOS 27. Aucune mise à niveau de l’OS n’est impliquée par ce projet.

## Références Apple

- [LanguageModelExecutor](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor)
- [Intégration de modèles personnalisés, WWDC26](https://developer.apple.com/videos/play/wwdc2026/339/)
- [Usage d’une session](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/usage-swift.property)
- [Orchestration des outils](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)
