import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// L'onglet Voix (règles 1 à 11). `read` et `update` sont doublés par des réglages en mémoire, dont l'enregistrement peut lever sur
/// ordre ; la liste des voix installées est inventée ; l'écoute est la vraie (`VoicePreview`) sur une voix double, un lecteur double
/// (`ScriptedClipPlayer`) et un trousseau en mémoire. Aucun son, aucune vraie voix, aucune vraie liste, aucun disque.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VoicesModelTests {
    struct ForeignError: LocalizedError {
        var errorDescription: String? { "échec vers https://api.example.com/v1/cle" }
    }

    static let provider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!, name: "Fournisseur d'exemple",
        baseURL: "https://example.com/v1", kind: .openAICompatible, models: ["modele-voix-exemple", "modele-exemple"])
    static let silentProvider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000d2")!, name: "Fournisseur sans voix",
        baseURL: "https://example.com/v2", kind: .anthropic, models: ["modele-exemple"])

    // Les voix installées inventées, données dans le désordre : deux langues, des genres et qualités variés.
    static let voiceB = SystemVoiceInfo(
        identifier: "voix.exemple.b", language: "fr-FR", quality: 3, name: "Voix d'exemple B", gender: .male)
    static let voiceA = SystemVoiceInfo(
        identifier: "voix.exemple.a", language: "fr-FR", quality: 2, name: "Voix d'exemple A", gender: .female)
    static let voiceC = SystemVoiceInfo(identifier: "voix.exemple.c", language: "en-US", quality: 1, name: "Voix d'exemple C")
    static let installed = [voiceB, voiceC, voiceA]

    static func saved(
        _ name: String, id: Int, language: String = "fr-FR", provider: UUID? = VoicesModelTests.provider.id,
        model: String? = "modele-voix-exemple", identifier: String? = "voix-exemple", gender: VoiceGender? = nil
    ) -> SavedVoice {
        SavedVoice(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!, name: name,
            voice: VoiceChoice(
                providerID: provider, model: model, identifier: identifier, language: language, gender: gender,
                extra: ["cle-exemple": "valeur-exemple"]))
    }

    static func settings(voices: [SavedVoice] = [], voice: VoiceChoice = .system) -> AppSettings {
        var settings = AppSettings.defaults
        settings.providers = [provider, silentProvider]
        settings.voices = voices
        settings.voice = voice
        return settings
    }

    /// Les réglages en mémoire, le double de `update` (appliqué aux réglages EN VIGUEUR, comme `AppController.updateSettings`, ou
    /// refusé sur ordre), la liste des voix (changeable), et la vraie écoute sur doubles.
    @MainActor final class Rig {
        var settings: AppSettings
        var updates = 0
        var failure: (any Error)?
        let voices: VoiceList
        let clock = PreviewClock()
        let factory = PreviewVoiceFactory(
            system: PreviewVoice(.clip(VoicePreviewTests.clip)), provider: PreviewVoice(.clip(VoicePreviewTests.clip)))
        let player = ScriptedClipPlayer(completion: .immediate)
        let keys = InMemorySecretStore(secrets: [VoicesModelTests.provider.id.uuidString: "cle-exemple"])
        lazy var model: VoicesModel = makeModel()

        init(_ settings: AppSettings, installed: [SystemVoiceInfo] = VoicesModelTests.installed) {
            self.settings = settings
            voices = VoiceList(installed)
        }

        func setInstalled(_ list: [SystemVoiceInfo]) { voices.value.withLock { $0 = list } }

        private func makeModel() -> VoicesModel {
            let access = SecretAccess(keys, queue: DispatchQueue(label: "test.voices.model.\(UUID())"))
            let factory = factory
            let clock = clock
            let preview = VoicePreview(
                makeVoice: { factory.make($0, $1) }, makePlayer: { [player] in player },
                resolve: { choice, settings in try await choice.resolve(in: settings, secrets: access) },
                sleep: { try await clock.sleep($0) })
            let voices = voices
            return VoicesModel(
                read: { self.settings },
                update: { change in
                    self.updates += 1
                    if let failure = self.failure { throw failure }
                    change(&self.settings)
                },
                systemVoices: { voices.value.withLock { $0 } },
                preview: preview)
        }
    }

    /// La liste des voix « installées », changeable par le test, lue sous verrou.
    final class VoiceList: Sendable {
        let value: Mutex<[SystemVoiceInfo]>
        init(_ list: [SystemVoiceInfo]) { value = Mutex(list) }
    }

    // MARK: - Règle 1 : lignes

    /// Par langue installée (dans l'ordre des langues), « Automatique » puis les voix de la langue par nom ; puis les voix
    /// enregistrées, par langue puis nom. Chaque ligne dit nom, langue, genre (ou « Genre non précisé ») et qualité ; une voix
    /// enregistrée dit son fournisseur et son modèle.
    @Test func rowsListSystemThenSaved() throws {
        let z = Self.saved("Zèbre", id: 1, language: "fr-FR")
        let a = Self.saved("Alouette", id: 2, language: "fr-FR", model: "modele-exemple")
        let e = Self.saved("Écho", id: 3, language: "en-US")
        let rig = Rig(Self.settings(voices: [z, a, e]))
        rig.model.language = nil
        let rows = rig.model.rows
        #expect(rows.map(\.id) == [
            .automatic(language: "en-US"), .system(identifier: "voix.exemple.c"),
            .automatic(language: "fr-FR"), .system(identifier: "voix.exemple.a"), .system(identifier: "voix.exemple.b"),
            .saved(e.id), .saved(a.id), .saved(z.id),
        ])
        try #require(rows.count == 8)
        #expect(rows.prefix(5).allSatisfy { $0.section == .system })
        #expect(rows.suffix(3).allSatisfy { $0.section == .provider })

        let automatic = rows[2]
        #expect(automatic.title == VoicesText.automatic)
        #expect(automatic.choice == VoiceChoice(language: "fr-FR"))
        #expect(automatic.choice.identifier == nil)

        let female = rows[3]
        #expect(female.title == "Voix d'exemple A")
        #expect(female.detail == "fr-FR · \(VoicesText.genderTitle(.female)) · \(VoicesText.quality(2))")
        #expect(female.choice == VoiceChoice(identifier: "voix.exemple.a", language: "fr-FR", gender: .female))
        let unspecified = rows[1]
        #expect(unspecified.detail == "en-US · \(VoicesText.genderUnspecified) · \(VoicesText.quality(1))")
        #expect(rows[4].detail.contains(VoicesText.quality(3)))

        let alouette = rows[6]
        #expect(alouette.title == "Alouette")
        #expect(alouette.detail == "Fournisseur d'exemple · modele-exemple")
        #expect(alouette.choice == a.voice)
        #expect(Set([1, 2, 3].map(VoicesText.quality)).count == 3, "trois qualités, trois libellés")
    }

    // MARK: - Règle 2 : la voix en vigueur est toujours listée et cochée

    @Test func theActiveVoiceIsAlwaysListed() {
        // Une voix installée en vigueur : sa ligne est cochée, une seule.
        let rig = Rig(Self.settings(voice: VoiceChoice(identifier: "voix.exemple.b", language: "fr-FR")))
        #expect(rig.model.rows.filter(\.isActive).map(\.id) == [.system(identifier: "voix.exemple.b")])

        // L'automatique de la langue en vigueur.
        let auto = Rig(Self.settings(voice: VoiceChoice(language: "fr-FR")))
        #expect(auto.model.rows.filter(\.isActive).map(\.id) == [.automatic(language: "fr-FR")])

        // Une voix du système qui n'est plus installée : une ligne « Voix en vigueur » qui le dit.
        let gone = Rig(Self.settings(voice: VoiceChoice(identifier: "voix.exemple.absente", language: "fr-FR")))
        let goneRow = gone.model.rows.first { $0.isActive }
        #expect(goneRow?.id == .active)
        #expect(goneRow?.title == VoicesText.activeVoice)
        #expect(goneRow?.note == VoicesText.noLongerInstalled)
        #expect(goneRow?.section == .system)
        #expect(gone.model.rows.filter(\.isActive).count == 1)

        // Une voix de fournisseur qui n'est pas enregistrée.
        let loose = Self.saved("Libre", id: 9).voice
        let unsaved = Rig(Self.settings(voice: loose))
        let unsavedRow = unsaved.model.rows.first { $0.isActive }
        #expect(unsavedRow?.id == .active)
        #expect(unsavedRow?.note == VoicesText.notSaved)
        #expect(unsavedRow?.section == .provider)
    }

    /// Deux voix enregistrées identiques : UNE ligne cochée, la première dans l'ordre affiché.
    @Test func twoIdenticalSavedVoicesCheckOnlyTheFirst() {
        let first = Self.saved("Alpha", id: 1)
        let second = Self.saved("Bêta", id: 2)
        let rig = Rig(Self.settings(voices: [second, first], voice: first.voice))
        #expect(rig.model.rows.filter(\.isActive).map(\.id) == [.saved(first.id)])
    }

    // MARK: - Règle 3 : voix enregistrée inutilisable

    @Test func anUnusableSavedVoiceIsListedAndSaysWhy() {
        let removed = Self.saved("Sans fournisseur", id: 1, provider: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff"))
        let mute = Self.saved("Muette", id: 2, provider: Self.silentProvider.id)
        let incomplete = Self.saved("Incomplète", id: 3, identifier: "  ")
        let good = Self.saved("Bonne", id: 4)
        let rig = Rig(Self.settings(voices: [removed, mute, incomplete, good]))
        let rows = Dictionary(uniqueKeysWithValues: rig.model.rows.map { ($0.id, $0) })
        #expect(rows[.saved(removed.id)]?.note == VoicesText.reason(.providerRemoved))
        #expect(rows[.saved(mute.id)]?.note == VoicesText.reason(.providerCannotSpeak))
        #expect(rows[.saved(incomplete.id)]?.note == VoicesText.reason(.incomplete))
        #expect(rows[.saved(good.id)]?.note == nil)
        #expect(rows[.saved(removed.id)]?.detail.hasPrefix(VoicesText.providerRemovedName) == true)
        for id in [removed.id, mute.id, incomplete.id] {
            #expect(rows[.saved(id)]?.canUse == false)
            rig.model.selection = .saved(id)
            #expect(!rig.model.canUse)
            rig.model.use()
        }
        #expect(rig.updates == 0, "« Utiliser » ne fait rien pour une voix inutilisable")
        #expect(rows[.saved(good.id)]?.canUse == true)
    }

    // MARK: - Règle 4 : filtres

    @Test func filtersNarrowButNeverHideTheActiveVoice() {
        let english = Self.saved("Écho", id: 1, language: "en-US", gender: .neutral)
        let rig = Rig(Self.settings(voices: [english], voice: VoiceChoice(identifier: "voix.exemple.a", language: "fr-FR")))
        let model = rig.model
        #expect(model.language == "fr-FR", "la langue par défaut est celle de la voix en vigueur")
        #expect(model.rows.map(\.id) == [
            .automatic(language: "fr-FR"), .system(identifier: "voix.exemple.a"), .system(identifier: "voix.exemple.b"),
        ])
        #expect(model.languages == ["en-US", "fr-FR"])

        model.language = nil
        #expect(model.rows.count == 6, "« Toutes les langues » montre tout")

        model.gender = .male
        #expect(model.rows.map(\.id) == [.system(identifier: "voix.exemple.a"), .system(identifier: "voix.exemple.b")],
                "le genre filtre ; la voix en vigueur (féminine) reste visible")
        model.gender = .neutral
        #expect(model.rows.map(\.id) == [.system(identifier: "voix.exemple.a"), .saved(english.id)])
        model.gender = .unspecified
        #expect(model.rows.map(\.id) == [
            .automatic(language: "en-US"), .system(identifier: "voix.exemple.c"), .automatic(language: "fr-FR"),
            .system(identifier: "voix.exemple.a"),
        ])
        model.gender = .female
        model.language = "en-US"
        #expect(model.rows.map(\.id) == [.system(identifier: "voix.exemple.a")], "en vigueur, hors filtre, toujours là")
        #expect(VoicesModel.GenderFilter.allCases.map(VoicesText.genderFilterTitle) == ["Tous", "Féminin", "Masculin", "Neutre", "Non précisé"])
    }

    // MARK: - Règle 5 : brouillon d'une voix de fournisseur

    @Test func theDraftOffersOnlyProvidersThatSpeakAndTheirModels() {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.beginAdding()
        #expect(model.draft != nil)
        #expect(model.speakingProviders.map(\.id) == [Self.provider.id])
        #expect(model.draft?.providerID == Self.provider.id)
        #expect(model.models(for: Self.provider.id) == Self.provider.models)
        #expect(model.models(for: Self.silentProvider.id).isEmpty)
        model.cancel()
        #expect(model.draft == nil)
        #expect(rig.updates == 0)
    }

    enum Refusal: String, CaseIterable, CustomTestStringConvertible {
        case emptyName, noProvider, silentProvider, emptyModel, emptyIdentifier, emptyKey, reservedKey, reservedKeyAnyCase,
            duplicateKey, tooManyParameters
        var testDescription: String { rawValue }
    }

    /// Un brouillon complet et valable, que chaque cas abîme d'une seule façon.
    static func validDraft() -> VoicesModel.VoiceDraft {
        VoicesModel.VoiceDraft(
            name: "Voix d'exemple A", providerID: provider.id, model: "modele-voix-exemple", identifier: "voix-exemple",
            language: "fr-FR", gender: .female,
            parameters: [VoicesModel.VoiceDraft.Parameter(key: "cle-exemple", value: "valeur-exemple")])
    }

    @Test(arguments: Refusal.allCases)
    func everyRefusalHasItsSentenceAndWritesNothing(_ refusal: Refusal) {
        let rig = Rig(Self.settings())
        let before = rig.settings
        let model = rig.model
        model.beginAdding()
        var draft = Self.validDraft()
        let expected: String
        switch refusal {
        case .emptyName:
            draft.name = "   "
            expected = VoicesText.refusalEmptyName
        case .noProvider:
            draft.providerID = nil
            expected = VoicesText.refusalNoProvider
        case .silentProvider:
            draft.providerID = Self.silentProvider.id
            expected = VoicesText.refusalNoProvider
        case .emptyModel:
            draft.model = " "
            expected = VoicesText.refusalEmptyModel
        case .emptyIdentifier:
            draft.identifier = ""
            expected = VoicesText.refusalEmptyIdentifier
        case .emptyKey:
            draft.parameters.append(.init(key: "  ", value: "valeur-exemple"))
            expected = VoicesText.refusalEmptyKey
        case .reservedKey:
            draft.parameters.append(.init(key: "voice", value: "valeur-exemple"))
            expected = VoicesText.refusalReservedKey
        case .reservedKeyAnyCase:
            draft.parameters.append(.init(key: " Response_Format ", value: "valeur-exemple"))
            expected = VoicesText.refusalReservedKey
        case .duplicateKey:
            draft.parameters.append(.init(key: " cle-exemple", value: "autre"))
            expected = VoicesText.refusalDuplicateKey
        case .tooManyParameters:
            draft.parameters = (0...VoiceChoice.maxExtraEntries).map { .init(key: "cle-\($0)", value: "valeur-exemple") }
            expected = VoicesText.refusalTooManyParameters
        }
        model.draft = draft
        model.save()
        #expect(model.message == expected)
        #expect(rig.updates == 0, "rien n'est écrit")
        #expect(rig.settings == before)
        #expect(model.draft == draft, "le brouillon reste")
    }

    /// Les phrases de refus : distinctes ; celle des clés réservées nomme les quatre, construite depuis la constante.
    @Test func theRefusalSentencesAreDistinctAndTheReservedOneNamesTheFourKeys() {
        let sentences = [
            VoicesText.refusalEmptyName, VoicesText.refusalNoProvider, VoicesText.refusalEmptyModel,
            VoicesText.refusalEmptyIdentifier, VoicesText.refusalEmptyKey, VoicesText.refusalReservedKey,
            VoicesText.refusalDuplicateKey, VoicesText.refusalTooManyParameters,
        ]
        #expect(Set(sentences).count == sentences.count)
        for key in VoiceChoice.reservedExtraKeys { #expect(VoicesText.refusalReservedKey.contains("«\u{00A0}\(key)\u{00A0}»")) }
        #expect(VoicesText.refusalTooManyParameters.contains("\(VoiceChoice.maxExtraEntries)"))
    }

    /// Accepté : une seule écriture de `voices`, sur les réglages en vigueur relus (un changement fait ailleurs reste) ; ce qui est
    /// écrit est la forme normalisée ; le brouillon se ferme et la nouvelle voix est choisie. La voix en vigueur ne bouge pas.
    @Test func aValidDraftIsSavedOnceNormalized() throws {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.beginAdding()
        var draft = Self.validDraft()
        draft.name = "  Voix d'exemple A  "
        draft.model = " modele-voix-exemple "
        draft.parameters = [.init(key: " cle-exemple ", value: "valeur-exemple")]
        model.draft = draft
        rig.settings.hotKeyBehavior = .hold   // écrit ailleurs entre-temps
        model.save()
        #expect(rig.updates == 1)
        #expect(model.message == nil)
        #expect(model.draft == nil)
        let saved = try #require(rig.settings.voices.first)
        #expect(rig.settings.voices.count == 1)
        #expect(saved.name == "Voix d'exemple A")
        #expect(saved.voice == saved.voice.normalized)
        #expect(saved.voice.model == "modele-voix-exemple")
        #expect(saved.voice.extra == ["cle-exemple": "valeur-exemple"])
        #expect(saved.voice.providerID == Self.provider.id && saved.voice.gender == .female)
        #expect(rig.settings.voice == .system, "ajouter ne change pas la voix en vigueur")
        #expect(rig.settings.hotKeyBehavior == .hold, "ce qui s'est écrit ailleurs reste")
        #expect(model.selection == .saved(saved.id))
    }

    /// Modifier la voix en vigueur (la ligne cochée) met à jour la liste ET `settings.voice`, dans la même écriture. Modifier la
    /// seconde de deux voix identiques (non cochée) ne touche pas `settings.voice`.
    @Test func savingTheActiveVoiceUpdatesBoth() throws {
        let first = Self.saved("Alpha", id: 1)
        let second = Self.saved("Bêta", id: 2)
        let rig = Rig(Self.settings(voices: [first, second], voice: first.voice))
        let model = rig.model
        // La jumelle non cochée d'abord : elle EST la même voix que la voix en vigueur, mais pas la ligne cochée.
        model.selection = .saved(second.id)
        model.beginEditing()
        model.draft?.model = "modele-exemple"
        model.save()
        #expect(rig.updates == 1)
        #expect(rig.settings.voice == first.voice, "la jumelle non cochée n'était pas la voix en vigueur")
        #expect(rig.settings.voices.first { $0.id == second.id }?.voice.model == "modele-exemple")

        model.selection = .saved(first.id)
        model.beginEditing()
        #expect(model.draft?.name == "Alpha")
        #expect(model.draft?.parameters.map(\.key) == ["cle-exemple"])
        model.draft?.identifier = "voix-exemple-neuve"
        model.save()
        #expect(rig.updates == 2, "une seule écriture de plus")
        let edited = try #require(rig.settings.voices.first { $0.id == first.id })
        #expect(edited.voice.identifier == "voix-exemple-neuve")
        #expect(rig.settings.voice == edited.voice, "la voix en vigueur suit")
    }

    /// Modifier une voix garde ce que cette version ne connaît pas (son identité, ses champs inconnus) : la voix enregistrée est
    /// modifiée en place, pas remplacée par une neuve.
    @Test func editingKeepsTheSavedVoiceInPlace() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Alpha","avenir":1,"voice":{"providerID":"00000000-0000-0000-0000-0000000000d1","model":"modele-voix-exemple","identifier":"voix-exemple","language":"fr-FR","futur":2}}"#
        let decoded = try JSONDecoder().decode(SavedVoice.self, from: Data(json.utf8))
        let rig = Rig(Self.settings(voices: [decoded]))
        rig.model.selection = .saved(decoded.id)
        rig.model.beginEditing()
        rig.model.draft?.name = "Alpha modifiée"
        rig.model.save()
        let written = String(decoding: try JSONEncoder().encode(rig.settings.voices[0]), as: UTF8.self)
        #expect(written.contains("\"avenir\"") && written.contains("\"futur\""))
        #expect(rig.settings.voices[0].name == "Alpha modifiée")
    }

    // MARK: - Règle 6 : utiliser, supprimer

    @Test func useWritesOnlyTheVoice() {
        let saved = Self.saved("Alpha", id: 1, model: " modele-voix-exemple ")
        let rig = Rig(Self.settings(voices: [saved]))
        let model = rig.model
        model.language = nil
        var expected = rig.settings

        model.selection = .system(identifier: "voix.exemple.b")
        model.use()
        expected.voice = VoiceChoice(identifier: "voix.exemple.b", language: "fr-FR", gender: .male)
        #expect(rig.settings == expected)
        #expect(rig.settings.voice.providerID == nil)

        model.selection = .automatic(language: "en-US")
        model.use()
        expected.voice = VoiceChoice(language: "en-US")
        #expect(rig.settings == expected)

        model.selection = .saved(saved.id)
        model.use()
        expected.voice = saved.voice.normalized
        #expect(rig.settings == expected)
        #expect(rig.settings.voices == [saved], "la liste ne bouge pas")
        #expect(rig.updates == 3)
        #expect(model.rows.first { $0.isActive }?.id == .saved(saved.id))
    }

    @Test func deletingTheActiveVoiceFallsBackAndSaysSo() {
        let first = Self.saved("Alpha", id: 1)
        let other = Self.saved("Bêta", id: 2, model: "modele-exemple")
        let rig = Rig(Self.settings(voices: [first, other], voice: first.voice))
        let model = rig.model

        model.selection = .saved(first.id)
        model.confirmDeletion()
        #expect(rig.updates == 0, "rien sans demande")
        model.requestDeletion()
        #expect(model.confirmationText == VoicesText.deleteConfirmation)
        #expect(rig.updates == 0, "rien avant la confirmation")
        model.cancelConfirmation()
        #expect(model.confirmationText == nil)
        model.confirmDeletion()
        #expect(rig.updates == 0, "une demande annulée ne supprime rien")

        model.requestDeletion()
        model.confirmDeletion()
        #expect(rig.updates == 1, "une seule écriture")
        #expect(rig.settings.voices == [other])
        #expect(rig.settings.voice == VoiceChoice.system, "la voix automatique du système, en français")
        #expect(model.message == VoicesText.deletedActive)
        #expect(model.confirmationText == nil)

        model.selection = .saved(other.id)
        model.requestDeletion()
        model.confirmDeletion()
        #expect(rig.settings.voices.isEmpty)
        #expect(rig.settings.voice == VoiceChoice.system)
        #expect(model.message == nil, "une voix qui n'était pas en vigueur : rien à dire")
    }

    /// Supprimer la seconde de deux voix identiques (non cochée) ne change pas la voix en vigueur.
    @Test func deletingTheUncheckedTwinKeepsTheActiveVoice() {
        let first = Self.saved("Alpha", id: 1)
        let second = Self.saved("Bêta", id: 2)
        let rig = Rig(Self.settings(voices: [first, second], voice: first.voice))
        rig.model.selection = .saved(second.id)
        rig.model.requestDeletion()
        rig.model.confirmDeletion()
        #expect(rig.settings.voices == [first])
        #expect(rig.settings.voice == first.voice)
        #expect(rig.model.message == nil)
    }

    // MARK: - Règle 7 : écoute d'une voix du système absente

    /// Une voix du système désignée qui n'est pas (ou plus) dans la liste : `.failed(.notInstalled)`, sans fabriquer de voix.
    @Test func aMissingSystemVoiceIsSaidWithoutSynthesis() async {
        let rig = Rig(Self.settings(voice: VoiceChoice(identifier: "voix.exemple.absente", language: "fr-FR")))
        let model = rig.model
        model.selection = .active
        model.listen()
        #expect(model.previewState == .failed(.notInstalled))
        #expect(model.previewMessage == VoicesText.failure(.notInstalled))

        // Listée à l'ouverture, désinstallée avant l'écoute : la liste est relue.
        model.selection = .system(identifier: "voix.exemple.a")
        rig.setInstalled([Self.voiceB, Self.voiceC])
        model.listen()
        #expect(model.previewState == .failed(.notInstalled))
        await settle()
        #expect(rig.factory.calls.isEmpty, "aucune voix fabriquée")
        #expect(rig.player.clips.isEmpty)
    }

    /// Une voix installée s'écoute : l'état suit l'écoute jusqu'à `.idle` ; « arrêter » la coupe.
    @Test func listeningFollowsThePreviewAndStopListeningStopsIt() async {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.selection = .system(identifier: "voix.exemple.a")
        model.listen()
        #expect(await until { rig.player.clips.count == 1 })
        #expect(await until { model.previewState == .idle })
        #expect(rig.factory.calls.map(\.choice.identifier) == ["voix.exemple.a"])
        model.stopListening()
        #expect(model.previewState == .idle)
        #expect(rig.player.stopNowCount == 1)
    }

    // MARK: - Règle 10 : vie privée

    @Test func thePrivacyNoteFollowsTheRoute() {
        let good = Self.saved("Bonne", id: 1)
        let mute = Self.saved("Muette", id: 2, provider: Self.silentProvider.id)
        let rig = Rig(Self.settings(voices: [good, mute]))
        let model = rig.model
        #expect(model.privacyText == nil, "aucune ligne choisie")
        model.selection = .system(identifier: "voix.exemple.a")
        #expect(model.privacyText == VoicesText.privacyNothingSent)
        model.selection = .saved(good.id)
        #expect(model.privacyText == VoicesText.privacyProvider("Fournisseur d'exemple"))
        #expect(model.privacyText == InterviewText.fr(
            "Écouter cette voix envoie la phrase d'essai à « Fournisseur d'exemple » et lit sa clé dans le trousseau."))
        model.selection = .saved(mute.id)
        #expect(model.privacyText == VoicesText.privacyNothingSent, "une voix qui ne peut pas parler n'envoie rien")
    }

    // MARK: - Règle 11 : écriture refusée

    @Test func aRefusedWriteSaysTheSettingsSentenceOrTheFixedOneAndRereads() {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.selection = .system(identifier: "voix.exemple.a")
        let refusal = SettingsError.unreadableFileKept(fileName: "settings.json")
        rig.failure = refusal
        model.use()
        #expect(model.message == refusal.errorDescription)
        #expect(rig.settings.voice == .system)
        rig.failure = ForeignError()
        model.use()
        #expect(model.message == VoicesText.saveFailure)
        #expect(model.message?.contains("https") == false)
        #expect(model.rows.first { $0.isActive }?.id == .automatic(language: "fr-FR"), "l'affichage est relu")
        rig.failure = nil
        model.use()
        #expect(model.message == nil)
    }
}
