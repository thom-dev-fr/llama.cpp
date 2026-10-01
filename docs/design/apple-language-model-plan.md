# Plan d’implémentation — Apple LanguageModel sur llama.cpp

## Mission et documents de référence

Livrer une bibliothèque Swift réutilisable implémentant le protocole Foundation Models `LanguageModel` sur le moteur embarqué de llama.cpp, et une nouvelle application SwiftUI de démonstration pour iOS 27 et macOS 27. Ce document est le point d’entrée de l’agent d’implémentation ; sa préparation ne lance pas l’implémentation.

Lire d’abord [la conception et les décisions utilisateur](apple-language-model.md), [le vocabulaire](../../CONTEXT.md), puis les ADR [moteur embarqué](../adr/0001-embedded-inference-engine.md), [runtime partagé](../adr/0002-shared-apple-inference-runtime.md) et [acquisition Apple](../adr/0003-apple-model-acquisition.md). La conception fait autorité sur le comportement produit ; ce plan définit l’ordre des travaux et leur validation.

Les derniers réglages proposés dans la conception restent des hypothèses d’exécution réversibles : une génération active, quatre demandes en attente, Qwen3.5-2B Q4_K_M comme premier candidat, profils de contexte mesurés. Leur qualification peut modifier les valeurs, avec justification dans le rapport. Ils ne constituent pas des performances ou une compatibilité déjà validées.

La livraison couvre les quatre capacités natives du SDK étudié — génération structurée, outils, raisonnement, vision — lorsque le modèle et le moteur les permettent. Une option incompatible est refusée explicitement. L’objectif ne se réduit pas à une enveloppe texte autour du moteur.

## Architecture de travail

```text
Nouvelle démo SwiftUI
  ├─ LanguageModelSession / Tool / @Generable (Foundation Models)
  │    └─ LlamaLanguageModel + executor
  │         └─ runtime Swift explicitement partagé
  │              └─ pont C interne → llama-engine → llama / ggml / mtmd
  └─ acquisition URLSession + stockage géré → catalogue du runtime
```

Foundation Models possède le transcript et orchestre les outils. Le runtime possède les ressources et l’admission ; le moteur reste responsable de l’inférence et du chargement. Une session, une requête et un slot sont trois identités distinctes.

Arborescence proposée, à créer sans déplacer les exemples existants :

| Emplacement | Rôle |
| --- | --- |
| `bindings/apple/Package.swift` | Package Swift et dépendance vers le XCFramework construit localement. |
| `bindings/apple/bridge/` | Interface C à handles opaques, implémentée en C++ au-dessus de l’API publique du moteur. |
| `bindings/apple/Sources/LlamaEngine/` | Runtime, configuration, catalogue, acquisition, observation et erreurs Swift typées. |
| `bindings/apple/Sources/LlamaFoundationModels/` | Modèle Apple, executor et conversions du contrat Foundation Models. |
| `bindings/apple/Tests/` | Tests du runtime, de l’adaptateur et des scénarios déterministes. |
| `scripts/build-apple-language-model.sh` | Construction dédiée du binaire Apple et de son archive distribuable. |
| `examples/llama.foundationmodels/` | Projet Xcode partagé iOS/macOS, catalogue de démonstration et README. |
| `docs/design/apple-language-model-report.md` | Matrice de compatibilité, résultats, mesures et limitations de livraison. |

Ces noms sont proposés, pas des fichiers déjà présents. Le module C demeure un détail d’intégration ; les applications consomment des types Swift. Exposer uniquement les opérations moteur nécessaires à cette livraison, avec possibilité d’extension ultérieure.

## P0 — Fixer le contrat exécutable

1. Lire les éventuels `AGENTS.md`, relever l’état Git et identifier les changements déjà présents. Les artefacts `build-*` historiques ne constituent pas une implémentation à récupérer implicitement.
2. Vérifier la swiftinterface Foundation Models du Xcode sélectionné : signatures de `LanguageModel`, `LanguageModelExecutor`, configuration, canal, transcript, schémas, capacités et erreurs. Le SDK réellement compilé prime sur une documentation d’une autre version.
3. Construire dans le rapport une matrice par capacité : entrée Apple, opération moteur, sortie attendue, restrictions, test associé. Inclure options de sampling, seed, guides, outils obligatoires/interdits, images, raisonnement et combinaisons.
4. Relever les destinations Xcode, signatures disponibles et modèles locaux. Conserver le constat actuel : Mac sous 26.7, SDK 27, simulateur iOS 27 et iPhone appairé ; vérifier à nouveau avant les tests.

**Sortie :** matrice traçable et squelette de conformité compilable pour les deux cibles, sans prétendre que des capacités non exécutées sont validées. Audio, embeddings et reranking restent hors protocole dans le SDK étudié.

## P1 — Compléter les signaux publics du moteur

Points d’entrée : `include/llama-engine.h`, `engine/engine-context.cpp`, `engine/server-task.cpp`, `engine/engine-operations.cpp`, `engine/llama-engine.cpp` et [contrat existant](embedded-inference-engine-api.md).

1. Distinguer prompt trop long, contexte épuisé pendant génération et plafond volontaire de tokens de sortie. Désactiver le context shift pour les requêtes de l’adaptateur. Aujourd’hui le chemin chat peut transformer les deux derniers cas en `finish_reason: length` : exposer un motif public fiable, puis le traduire côté Swift.
2. Donner à chaque mesure une identité de requête et sa capacité effective. Vérifier exactement les compteurs existants avant de les réutiliser : prompt ingéré, tokens générés, cache réutilisé, tokens de raisonnement et coût des images/outils. Un snapshot global de slots ne suffit pas à attribuer une mesure à une session concurrente.
3. Ajouter les informations manquantes de façon compatible. Préserver le comportement observable du serveur et du CLI ; si une nouvelle politique d’erreur modifie leur résultat, la rendre explicite et propre au consommateur demandeur.
4. Réutiliser les tests `tests/test-engine-operations.cpp`, `test-engine-events.cpp`, `test-engine-lifecycle.cpp` et les fixtures appropriées. Documenter les extensions publiques.

**Sortie :** tests prouvant les trois motifs d’arrêt, des métriques attribuées correctement à deux requêtes intercalées, et absence de régression du contrat des consommateurs existants.

## P2 — Pont natif et distribution Apple

1. Implémenter le pont C : handles de moteur/requête/abonnement, soumission avec pièces jointes, lecture bornée des événements, annulation, catalogue, chargement, déchargement et mise à jour du catalogue. Les exceptions C++ deviennent des erreurs possédées et libérables ; aucune exception ne traverse la frontière C.
2. Définir ownership et durée de vie des buffers, chaînes et pièces jointes. Un seul lecteur par requête ; annulation concurrente autorisée ; destruction après arrêt des utilisateurs du handle. Couvrir annulation pendant lecture et destruction pendant arrêt du moteur.
3. Exécuter les opérations bloquantes (`next`, `unload`, destruction, préparation coûteuse) sur des workers dédiés. Préserver la réactivité du MainActor et du pool coopératif Swift. Une simple fonction `async` n’isole pas un appel natif bloquant.
4. Construire le XCFramework avec `LLAMA_BUILD_ENGINE`, ses dépendances locales, mtmd et Metal. Le réseau du moteur reste optionnel puisque l’acquisition Apple utilise URLSession. Préserver les builds et versions minimales du `build-xcframework.sh` existant ; utiliser des répertoires de sortie dédiés sans nettoyage global des artefacts de l’utilisateur.
5. Livrer les slices iOS appareil, simulateur et macOS prises en charge par le SDK, avec module map, dépendances natives et ressources Metal nécessaires. Vérifier le lien depuis un consommateur externe au dépôt.
6. Fournir une reconstruction locale et une archive XCFramework avec checksum SPM. Le package local doit être exploitable sans URL fictive ; documenter la préparation de la variante à URL pour une publication ultérieure. La publication d’une release n’est pas un prérequis du travail local.

**Sortie :** un consommateur Swift importe et lie les modules pour iOS 27 et macOS 27 ; le pont possède des tests de durée de vie ; la procédure produit l’archive depuis un checkout propre. Les tests utilisant les API OS 27 tournent sur une destination compatible, pas sur le Mac 26.7.

## P3 — Runtime Swift partagé et stockage des modèles

1. Créer une instance de runtime explicite, sans singleton caché. Séparer identité d’un artefact, profil de chargement et session. Deux sessions au même profil partagent les poids ; deux configurations incompatibles ne partagent pas accidentellement les mêmes ressources.
2. Exposer une configuration Swift typée : limites de résidence/concurrence/attente, profil de contexte, configuration de calcul et modèle/projecteur. Définir une identité `Hashable` et `Sendable` de configuration d’executor stable et liée au runtime approprié.
3. Implémenter l’admission bornée et annulable, avec états observables. Articuler la file Swift et les limites natives pour éviter deux files contradictoires. Une annulation libère son admission une seule fois ; un travail n’obtient pas un nouveau départ après annulation ou fermeture.
4. Mutualiser les demandes simultanées de chargement ; conserver la distinction native entre annuler une attente et interrompre un chargement déjà commencé. Le déchargement explicite ferme les admissions du modèle, annule ses travaux et attend leur fin sans bloquer l’UI.
5. Exposer snapshots et changements d’état, y compris resynchronisation d’un abonné lent. Les deltas de génération ne peuvent pas être perdus silencieusement ; le buffering Swift doit lui aussi être borné et annoncer sa saturation.
6. Stocker catalogue et réglages dans le sandbox de l’application. Importer par copie temporaire puis finalisation atomique ; gérer fichiers GGUF segmentés s’ils sont annoncés, projecteur, espace insuffisant et suppression. Conserver le fichier source intact et exclure les gros poids re-téléchargeables de la sauvegarde système.
7. Mettre à jour le catalogue natif sans reconstruire les modèles inchangés ; interdire les courses entre import, suppression, chargement et génération.

**Sortie :** deux sessions indépendantes partagent un modèle ; tests de file pleine, annulation en attente, déchargement en cours, resynchronisation, import et suppression. Les historiques survivent au déchargement, les poids sont effectivement libérés après terminaison des travaux.

## P4 — Acquisition URLSession et catalogue qualifié

1. Définir un manifeste versionné de modèles : références exactes/révisions, fichiers et intégrité vérifiable, projecteur, licence, template et capacités qualifiées. Partir du candidat local Qwen ; valider références et compatibilité avant de figer le catalogue.
2. Implémenter les transferts avec une session de fond et des identités persistantes. Documenter le raccordement requis au cycle de vie de l’application ; reconnecter les tâches lors d’une relance système.
3. Gérer progression, erreurs, pause/reprise quand disponible et redémarrage propre lorsque les données de reprise sont inutilisables. Distinguer une interruption récupérable d’un abandon explicite. Tester serveur sans support de reprise et fichiers modifiés côté serveur.
4. Ne rendre le modèle chargeable qu’une fois l’ensemble nécessaire finalisé et validé. Un projecteur partiellement téléchargé ne doit pas produire une capacité vision utilisable.

**Sortie :** tests réseau avec serveur contrôlé pour interruption, reprise, erreur et intégrité ; scénario réel de transfert en arrière-plan sur iPhone. Les restrictions de relance imposées par iOS sont documentées, sans promesse de poursuite après fermeture forcée par l’utilisateur.

## P5 — LanguageModel, executor et conformité Foundation Models

1. Garder le modèle Apple léger ; son executor utilise le runtime partagé. `prewarm` est une optimisation facultative : `respond` fonctionne sans appel préalable et charge un modèle local si nécessaire.
2. Traduire le transcript complet à chaque requête : instructions, messages, outils, résultats, images et raisonnement. Maintenir IDs et ordre. Laisser le moteur réutiliser seulement les préfixes compatibles ; le cache ne remplace jamais le transcript et n’est pas l’identité de la conversation.
3. Traduire les options exactement. Vérifier notamment largeur/réservation de la seed native, sampling greedy/top-k/top-p, limite de sortie et effort de raisonnement. Refuser les valeurs sans représentation fidèle avant lancement quand possible.
4. Convertir les schémas Apple vers la génération contrainte : objets, optionnels/null, enums, tableaux, références et guides. Auditer les restrictions du convertisseur de grammaire. Une capacité générale ne signifie pas que toute contrainte est acceptée ; le diagnostic doit localiser la contrainte refusée.
5. Produire les événements du canal Apple : texte, raisonnement distinct, arguments d’outils fragmentés et usage. Préserver UTF-8, frontières des segments, IDs d’appels et ordre des deltas ; traiter un JSON d’outil partiel comme incomplet. La terminaison du canal découle du retour ou de l’erreur de l’executor selon le SDK.
6. Traduire les politiques d’outils autorisés/obligatoires/interdits, puis laisser Foundation Models exécuter les `Tool` et soumettre le transcript enrichi. Tester plusieurs appels et la combinaison outils + réponse structurée.
7. Convertir les images avec orientation et position conservées ; posséder leurs données pendant la requête et utiliser le projecteur compatible. Rejeter les entrées multimodales incompatibles avant calcul lorsque détectables.
8. Propager l’annulation Swift jusqu’à la requête native, puis nettoyer readers et admissions. Une erreur après émission de fragments reste une erreur ; ne pas déclarer la réponse terminée avec succès.
9. Mapper les erreurs vers les types Apple réellement disponibles ; conserver les diagnostics moteur et distinguer contexte plein, capacité absente, file pleine, modèle invalide et interruption. Respecter le rollback Foundation Models et valider la requête suivante après erreur.

**Sortie :** tests déterministes du vrai adaptateur alimenté par une frontière moteur contrôlée, complétés par un modèle/executor scripté pour vérifier les comportements du framework. Puis tests avec modèle réel pour chacune des capacités annoncées. Un mock du modèle Apple seul ne prouve pas la justesse de l’adaptateur.

## P6 — Nouvelle démo SwiftUI

1. Créer un projet Xcode reproductible avec schémas partagés, dépendance au package et cibles iOS/macOS 27. Garder `examples/llama.swiftui` fonctionnel et indépendant.
2. Fournir bibliothèque de modèles, téléchargement/import, chargement/déchargement et suppression. Afficher les états distincts du téléchargement, de la file, du chargement, du traitement du prompt et de la génération.
3. Ajouter chat streamé, images, détail du raisonnement, appels/résultats des deux outils locaux et scénario `@Generable`. Présenter les erreurs de compatibilité au niveau de l’action concernée.
4. Afficher deux indicateurs : progression du prompt et occupation/capacité effective. En dehors de la requête, qualifier la dernière mesure ; état indisponible distinct de zéro. Ne jamais substituer `session.usage` à l’occupation.
5. Garder les fragments interrompus dans le modèle de présentation, séparés du transcript autoritatif. « Réessayer » soumet une fois la demande depuis le dernier tour complet. Un changement de modèle crée une nouvelle conversation ; les anciennes restent consultables en mémoire.
6. Annuler les travaux d’inférence de la démo au passage réel en arrière-plan iOS, sans confondre une inactivité transitoire liée à un sélecteur de fichiers avec la suspension de l’app. Sur macOS, la perte de focus ne déclenche pas cette politique. Les téléchargements suivent leur propre cycle de vie.

**Sortie :** les parcours fonctionnent depuis une installation vide et depuis un modèle déjà présent ; aucune action longue ne bloque l’interface ; fermeture/réouverture conserve réglages et modèles, sans restaurer les conversations.

## P7 — Qualification et livraison

1. Exécuter les tests natifs pertinents avec les fixtures requises ; relever les tests effectivement enregistrés par CTest. Un succès avec zéro test d’intégration configuré ne valide pas le moteur réel.
2. Exécuter la suite Swift sur iOS 27, puis qualifier sur iPhone : texte, structuré streamé, outils, raisonnement, vision, combinaisons, deux sessions, contexte plein avant/pendant génération et récupération après interruption.
3. Mesurer mémoire, premier token, débit et délai d’annulation. Fixer les profils de contexte et de calcul à partir de ces mesures ; ne pas déduire la résidence mémoire de la taille des fichiers.
4. Tester compilation et linkage macOS 27. Exécuter les mêmes scénarios natifs sur macOS 27 dès qu’une machine est disponible. Sinon marquer cette validation comme manquante et la livraison comme partiellement qualifiée, sans annoncer une couverture complète.
5. Documenter commandes réellement exécutées, SDK, OS, appareil, révision des modèles, résultats et restrictions. Distinguer tests réussis, échoués, ignorés et non exécutables.
6. Livrer README du package, README de la démo, matrice de compatibilité et rapport. Un autre développeur doit pouvoir reconstruire le XCFramework et lancer l’exemple à partir des instructions.

**Terminé lorsque :** chaque capacité annoncée possède une preuve d’exécution, les parcours de cycle de vie et les erreurs ont des tests, la distribution est reconstructible et les validations de plateforme manquantes sont explicites. Une simple compilation ne clôt pas la qualification des capacités.

## Dépendances et suivi

Ordre : **P0 → P1 → P2 → P3**. P4 dépend de P3 ; P5 dépend de P1–P3. P6 intègre P4 et P5 ; P7 valide l’ensemble. Vérifier tôt une chaîne verticale minimale — petit modèle local → moteur → pont → executor → un fragment affiché — avant d’élargir les capacités.

Tenir dans le rapport un tableau P0–P7 avec état, preuve et blocage éventuel. Résoudre les choix techniques réversibles au fil du travail. Si une contrainte du SDK contredit un comportement confirmé, exposer le cas précis et ses alternatives au lieu de réduire silencieusement le périmètre.

Préserver les changements existants et ne pas mettre à niveau l’OS, publier de binaires ou créer de release dans le cadre de cette implémentation locale. La validation macOS manquante n’empêche pas d’achever le travail indépendant sur iOS, le moteur, le package et la documentation.
