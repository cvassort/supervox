import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// L'onglet Voix (règles 1 à 11). `read` et `update` sont doublés par des réglages en mémoire, dont l'enregistrement peut lever sur
/// ordre ; la liste des voix installées est inventée ; l'écoute est la vraie (`VoicePreview`) sur une voix double, un lecteur double
/// (`ScriptedClipPlayer`) et un trousseau en mémoire. Aucun son, aucune vraie voix, aucune vraie liste, aucun disque.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VoicesModelTests {
    /// Écrit en toutes lettres à l'affectation : `= .system(` se lirait comme la construction de l'insertion du système
    /// (`SourceScanTests.noTestBuildsTheSystemInserter`).
    typealias RowID = VoicesModel.Row.ID

    struct ForeignError: LocalizedError {
        var errorDescription: String? { "échec vers https://api.example.com/v1/cle" }
    }

    static let provider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!, name: "Fournisseur d'exemple",
        baseURL: "https://example.com/v1", kind: .openAICompatible, models: ["modele-voix-exemple", "modele-exemple"])
    static let silentProvider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000d2")!, name: "Fournisseur d'exemple",
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
        /// Ce que le modèle lit pour griser « Écouter » (reflet d'affichage seulement).
        var busy = false
        let voices: VoiceList
        let clock = PreviewClock()
        let factory: PreviewVoiceFactory
        let player: ScriptedClipPlayer
        let keys = InMemorySecretStore(secrets: [VoicesModelTests.provider.id.uuidString: "cle-exemple"])
        lazy var model: VoicesModel = makeModel()

        /// `systemVoice` : la voix du système double (par défaut, elle rend un clip) ; `player` : le lecteur (par défaut, la
        /// lecture finit aussitôt).
        init(
            _ settings: AppSettings, installed: [SystemVoiceInfo] = VoicesModelTests.installed,
            systemVoice: PreviewVoice = PreviewVoice(.clip(VoicePreviewTests.clip)),
            player: ScriptedClipPlayer = ScriptedClipPlayer(completion: .immediate)
        ) {
            self.settings = settings
            voices = VoiceList(installed)
            factory = PreviewVoiceFactory(system: systemVoice, provider: PreviewVoice(.clip(VoicePreviewTests.clip)))
            self.player = player
        }

        /// Le micro tel que l'écoute le lit (la garantie).
        let microphone = MicrophoneFlag()

        func setInstalled(_ list: [SystemVoiceInfo]) { voices.set(list) }

        private func makeModel() -> VoicesModel {
            let access = SecretAccess(keys, queue: DispatchQueue(label: "test.voices.model.\(UUID())"))
            let factory = factory
            let clock = clock
            let voices = voices
            let microphone = microphone
            let preview = VoicePreview(
                makeVoice: { factory.make($0, $1) }, makePlayer: { [player] in player },
                resolve: { choice, settings in try await choice.resolve(in: settings, secrets: access) },
                systemVoices: { voices.read() }, microphoneHeld: { microphone.held },
                sleep: { try await clock.sleep($0) })
            return VoicesModel(
                read: { self.settings },
                update: { change in
                    self.updates += 1
                    if let failure = self.failure { throw failure }
                    change(&self.settings)
                },
                systemVoices: { voices.read() },
                preview: preview,
                microphoneBusy: { self.busy })
        }
    }

    // MARK: - Règle 1 : lignes

    /// Par langue installée (dans l'ordre des langues), « Automatique » puis les voix de la langue par nom ; puis les voix
    /// enregistrées, par langue puis nom. Chaque ligne dit nom, langue, genre (ou « Genre non précisé ») et qualité ; une voix
    /// enregistrée dit son fournisseur et son modèle.
    @Test func rowsListSystemThenSaved() throws {
        let z = Self.saved("Voix d'exemple F", id: 1, language: "fr-FR")
        let a = Self.saved("voix d'exemple É", id: 2, language: "fr-FR", model: "modele-exemple")
        let e = Self.saved("Voix d'exemple C", id: 3, language: "en-US")
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
        #expect(female.detail == "\(VoicesText.languageName("fr-FR")) · \(VoicesText.genderTitle(.female)) · \(VoicesText.quality(2))")
        #expect(female.choice == VoiceChoice(identifier: "voix.exemple.a", language: "fr-FR", gender: .female))
        let unspecified = rows[1]
        #expect(unspecified.detail == "\(VoicesText.languageName("en-US")) · \(VoicesText.genderUnspecified) · \(VoicesText.quality(1))")
        #expect(rows[4].detail.contains(VoicesText.quality(3)))

        // Le nom plié (sans casse ni accents) : « voix d'exemple É » passe avant « Voix d'exemple F ».
        let folded = rows[6]
        #expect(folded.title == "voix d'exemple É")
        #expect(folded.detail == "Fournisseur d'exemple · modele-exemple · \(VoicesText.languageName("fr-FR"))")
        #expect(folded.choice == a.voice)
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
        let loose = Self.saved("Voix d'exemple D", id: 9).voice
        let unsaved = Rig(Self.settings(voice: loose))
        let unsavedRow = unsaved.model.rows.first { $0.isActive }
        #expect(unsavedRow?.id == .active)
        #expect(unsavedRow?.note == VoicesText.notSaved)
        #expect(unsavedRow?.section == .provider)
    }

    /// Deux voix enregistrées identiques : UNE ligne cochée, la première dans l'ordre affiché.
    @Test func twoIdenticalSavedVoicesCheckOnlyTheFirst() {
        let first = Self.saved("Voix d'exemple A", id: 1)
        let second = Self.saved("Voix d'exemple B", id: 2)
        let rig = Rig(Self.settings(voices: [second, first], voice: first.voice))
        #expect(rig.model.rows.filter(\.isActive).map(\.id) == [.saved(first.id)])
    }

    // MARK: - Règle 3 : voix enregistrée inutilisable

    @Test func anUnusableSavedVoiceIsListedAndSaysWhy() {
        let removed = Self.saved("Voix d'exemple D", id: 1, provider: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff"))
        let mute = Self.saved("Voix d'exemple E", id: 2, provider: Self.silentProvider.id)
        let incomplete = Self.saved("Voix d'exemple F", id: 3, identifier: "  ")
        let good = Self.saved("Voix d'exemple G", id: 4)
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
        let english = Self.saved("Voix d'exemple C", id: 1, language: "en-US", gender: .neutral)
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

    /// Ce qui cache la voix neuve (filtre de langue, de genre, ou les deux) ; `none` : rien ne la cache (témoin) ;
    /// `blankLanguage` : le brouillon n'a pas de langue (la voix est écrite normalisée, dans la langue du système, `fr-FR`), et le
    /// filtre de langue la cache.
    enum HidingFilters: CaseIterable, Sendable {
        case language, gender, both, none, blankLanguage

        var language: String? { self == .gender || self == .none ? "fr-FR" : "en-US" }
        var gender: VoicesModel.GenderFilter { self == .gender || self == .both ? .male : .female }
    }

    /// R1 (tâche 4, tour 2, remplace la décision 11) : une voix qu'on vient d'enregistrer se voit. Cachée par les filtres en cours
    /// (la voix est en `fr-FR`, féminine), le filtre de langue passe à LA LANGUE ÉCRITE de cette voix (pas « toutes les
    /// langues », qui déroulait toutes les voix du système) et le filtre de genre à « tous » ; elle est alors choisie ET montrée
    /// (`selectedRow`). Rien ne la cache : les filtres ne bougent pas. (« Une voix sans langue » n'existe pas après
    /// l'enregistrement : `normalized` lui donne celle du système, cas `blankLanguage`.)
    @Test(arguments: HidingFilters.allCases)
    func aJustSavedVoiceIsShownAndChosen(_ hiding: HidingFilters) throws {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.language = hiding.language
        model.gender = hiding.gender
        model.beginAdding()
        model.draft = Self.validDraft()
        if hiding == .blankLanguage { model.draft?.language = "  " }
        model.save()
        let saved = try #require(rig.settings.voices.first)
        #expect(saved.voice.language == "fr-FR")
        #expect(model.selection == .saved(saved.id))
        #expect(model.selectedRow?.id == .saved(saved.id), "la ligne neuve est montrée (\(hiding))")
        #expect(model.rows.contains { $0.id == .saved(saved.id) })
        if hiding == .none {
            #expect(model.language == "fr-FR" && model.gender == .female, "rien ne la cachait : les filtres restent")
        } else {
            #expect(model.language == "fr-FR" && model.gender == .all, "la langue de la voix, et tous les genres (\(hiding))")
        }
    }

    /// R1 : une voix modifiée dont la nouvelle langue est hors du filtre reste choisie et montrée ; le filtre passe à sa langue.
    @Test func anEditedVoiceMovedOutOfTheFilterIsStillShown() throws {
        let saved = Self.saved("Voix d'exemple A", id: 1, gender: .female)
        let rig = Rig(Self.settings(voices: [saved]))
        let model = rig.model
        #expect(model.language == "fr-FR")
        model.selection = .saved(saved.id)
        model.beginEditing()
        model.draft?.language = "en-US"
        model.save()
        #expect(rig.settings.voices.first?.voice.language == "en-US")
        #expect(model.selectedRow?.id == .saved(saved.id))
        #expect(model.language == "en-US" && model.gender == .all)
    }

    /// Modifier la voix en vigueur (la ligne cochée) met à jour la liste ET `settings.voice`, dans la même écriture. Modifier la
    /// seconde de deux voix identiques (non cochée) ne touche pas `settings.voice`.
    @Test func savingTheActiveVoiceUpdatesBoth() throws {
        let first = Self.saved("Voix d'exemple A", id: 1)
        let second = Self.saved("Voix d'exemple B", id: 2)
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
        #expect(model.draft?.name == "Voix d'exemple A")
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
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Voix d'exemple A","avenir":1,"voice":{"providerID":"00000000-0000-0000-0000-0000000000d1","model":"modele-voix-exemple","identifier":"voix-exemple","language":"fr-FR","futur":2}}"#
        let decoded = try JSONDecoder().decode(SavedVoice.self, from: Data(json.utf8))
        let rig = Rig(Self.settings(voices: [decoded]))
        rig.model.selection = .saved(decoded.id)
        rig.model.beginEditing()
        rig.model.draft?.name = "Voix d'exemple A modifiée"
        rig.model.save()
        let written = String(decoding: try JSONEncoder().encode(rig.settings.voices[0]), as: UTF8.self)
        #expect(written.contains("\"avenir\"") && written.contains("\"futur\""))
        #expect(rig.settings.voices[0].name == "Voix d'exemple A modifiée")
    }

    // MARK: - Règle 6 : utiliser, supprimer

    @Test func useWritesOnlyTheVoice() {
        let saved = Self.saved("Voix d'exemple A", id: 1, model: " modele-voix-exemple ")
        let rig = Rig(Self.settings(voices: [saved]))
        let model = rig.model
        model.language = nil
        var expected = rig.settings

        model.selection = RowID.system(identifier: "voix.exemple.b")
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
        let first = Self.saved("Voix d'exemple A", id: 1)
        let other = Self.saved("Voix d'exemple B", id: 2, model: "modele-exemple")
        let rig = Rig(Self.settings(voices: [first, other], voice: first.voice))
        let model = rig.model

        model.selection = .saved(first.id)
        model.confirmDeletion()
        #expect(rig.updates == 0, "rien sans demande")
        model.requestDeletion()
        #expect(model.confirmationText == VoicesText.deleteConfirmation(name: "Voix d'exemple A", isActive: true))
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

    /// Décision 13a (tâche 4) : une demande de suppression ne survit pas à la disparition de sa ligne. Un filtre qui cache la ligne
    /// demandée lâche la demande ; la confirmation n'écrit rien et la voix reste.
    @Test func aPendingDeletionDoesNotSurviveItsRowBeingHidden() {
        let saved = Self.saved("Voix d'exemple A", id: 1, gender: .female)
        let rig = Rig(Self.settings(voices: [saved]))
        let model = rig.model
        model.selection = .saved(saved.id)
        model.requestDeletion()
        #expect(model.pendingDeletion == saved.id)
        model.gender = .male  // la ligne demandée est cachée
        #expect(model.selection == nil)
        #expect(model.pendingDeletion == nil, "la demande est lâchée avec sa ligne")
        #expect(model.confirmationText == nil)
        model.confirmDeletion()
        #expect(rig.updates == 0, "rien n'est écrit")
        #expect(rig.settings.voices == [saved], "la voix est toujours dans les réglages")
    }

    /// Décision 13a : la confirmation ne supprime que la voix en attente si elle est encore la ligne choisie et montrée ; la
    /// sélection passée à une autre ligne entre-temps, rien n'est écrit.
    @Test func confirmingDeletesOnlyThePendingVoiceStillChosenAndShown() {
        let first = Self.saved("Voix d'exemple A", id: 1)
        let other = Self.saved("Voix d'exemple B", id: 2)
        let rig = Rig(Self.settings(voices: [first, other]))
        let model = rig.model
        model.selection = .saved(first.id)
        model.requestDeletion()
        model.selection = .saved(other.id)
        model.confirmDeletion()
        #expect(rig.updates == 0, "la ligne choisie n'est plus la voix en attente")
        #expect(rig.settings.voices == [first, other])
        #expect(model.pendingDeletion == nil, "la demande est consommée")

        model.selection = .saved(first.id)
        model.requestDeletion()
        model.confirmDeletion()
        #expect(rig.updates == 1)
        #expect(rig.settings.voices == [other])
    }

    /// Supprimer la seconde de deux voix identiques (non cochée) ne change pas la voix en vigueur.
    @Test func deletingTheUncheckedTwinKeepsTheActiveVoice() {
        let first = Self.saved("Voix d'exemple A", id: 1)
        let second = Self.saved("Voix d'exemple B", id: 2)
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
        #expect(await until { model.previewState == .failed(.notInstalled) })
        #expect(model.previewMessage == VoicesText.failure(.notInstalled))

        // Listée à l'ouverture, désinstallée avant l'écoute : `listen()` relit la liste, la ligne n'est plus montrée, rien n'est
        // écouté (la panne d'avant est effacée par le changement de sélection : sans cela, l'attente passait sur l'ANCIENNE
        // panne). La désinstallation entre la décision et l'écoute est tenue par l'écoute elle-même (`VoicePreviewTests`).
        model.selection = RowID.system(identifier: "voix.exemple.a")
        #expect(model.previewState == .idle)
        rig.setInstalled([Self.voiceB, Self.voiceC])
        model.listen()
        #expect(model.selectedRow == nil, "la ligne désinstallée n'est plus montrée")
        #expect(model.listeningRow == nil)
        await settle()
        #expect(model.previewState == .idle)
        #expect(rig.factory.calls.isEmpty, "aucune voix fabriquée")
        #expect(rig.player.clips.isEmpty)
    }

    /// Une voix installée s'écoute : l'état suit l'écoute jusqu'à `.idle` ; « arrêter » la coupe.
    @Test func listeningFollowsThePreviewAndStopListeningStopsIt() async {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.selection = RowID.system(identifier: "voix.exemple.a")
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
        let good = Self.saved("Voix d'exemple G", id: 1)
        let mute = Self.saved("Voix d'exemple E", id: 2, provider: Self.silentProvider.id)
        let rig = Rig(Self.settings(voices: [good, mute]))
        let model = rig.model
        #expect(model.privacyText == nil, "aucune ligne choisie")
        model.selection = RowID.system(identifier: "voix.exemple.a")
        #expect(model.privacyText == VoicesText.privacyNothingSent)
        model.selection = .saved(good.id)
        #expect(model.privacyText == VoicesText.privacyProvider("Fournisseur d'exemple"))
        #expect(model.privacyText == InterviewText.fr(
            "Écouter cette voix envoie la phrase d'essai à « Fournisseur d'exemple » et lit sa clé dans le trousseau."))
        model.selection = .saved(mute.id)
        #expect(model.privacyText == VoicesText.privacyCannotSpeak, "une voix qui ne peut pas parler n'envoie rien")
        // Trois phrases distinctes ; celle d'une voix qui ne peut pas parler ne dit pas qu'elle est produite sur cet ordinateur.
        let notes = [VoicesText.privacyNothingSent, VoicesText.privacyCannotSpeak, VoicesText.privacyProvider("Fournisseur d'exemple")]
        #expect(Set(notes).count == 3)
        #expect(!VoicesText.privacyCannotSpeak.contains("ordinateur"))
        #expect(VoicesText.privacyCannotSpeak.contains("n'envoie rien"))
    }

    /// D6 : LA propriété « ce fournisseur sait parler », lue par la route, le brouillon et la fabrique.
    @Test func onlyTheCompatibleKindSpeaks() {
        #expect(ProviderKind.openAICompatible.canSpeak)
        #expect(!ProviderKind.anthropic.canSpeak)
    }

    // MARK: - Règle 11 : écriture refusée

    /// Une écriture refusée : la phrase de `SettingsError.sentence(forSaveError:)` (celle de la `SettingsError`, sinon la phrase
    /// fixe commune), jamais le texte de l'erreur ; puis l'affichage est relu (un changement fait ailleurs juste avant se voit).
    @Test func aRefusedWriteSaysTheSettingsSentenceOrTheFixedOneAndRereads() {
        let saved = Self.saved("Voix d'exemple A", id: 1)
        let rig = Rig(Self.settings(voices: [saved]))
        let model = rig.model
        model.language = nil
        model.selection = RowID.system(identifier: "voix.exemple.a")
        let refusal = SettingsError.unreadableFileKept(fileName: "settings.json")
        rig.failure = refusal
        model.use()
        #expect(model.message == SettingsError.sentence(forSaveError: refusal))
        #expect(model.message == refusal.errorDescription)
        #expect(rig.settings.voice == .system)

        // Écrit ailleurs juste avant l'écriture refusée : la voix enregistrée devient la voix en vigueur. L'écriture refusée est
        // une suppression (`confirmDeletion` ne relit pas avant d'écrire : seule la relecture d'après le refus peut le montrer).
        model.selection = .saved(saved.id)
        model.requestDeletion()
        rig.settings.voice = saved.voice
        #expect(model.rows.first { $0.isActive }?.id == .automatic(language: "fr-FR"), "pas encore relu")
        rig.failure = ForeignError()
        model.confirmDeletion()
        #expect(model.message == SettingsError.otherSaveFailure)
        #expect(model.message?.contains("https") == false)
        #expect(model.rows.first { $0.isActive }?.id == .saved(saved.id), "l'affichage est relu après le refus")
        rig.failure = nil
        // La ligne choisie est maintenant la voix en vigueur : « Utiliser » y est inactif (C3, tâche 4). Une autre ligne.
        model.selection = RowID.system(identifier: "voix.exemple.a")
        model.use()
        #expect(model.message == nil)
    }

    // MARK: - Tour de correction 1

    /// C1 : « Écouter » est grisé tant que le micro est tenu (reflet d'affichage). Le cas qui diverge : le modèle croit le micro
    /// libre, l'écoute le sait tenu et refuse ; l'état et la phrase le disent.
    @Test func listeningIsGreyedWhileTheMicrophoneIsBusyAndTheRefusalIsSaid() async {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.selection = RowID.system(identifier: "voix.exemple.a")
        #expect(model.canListen)
        rig.busy = true
        #expect(!model.canListen)
        rig.busy = false

        rig.microphone.held = true
        model.listen()
        #expect(model.previewState == .failed(.microphoneBusy))
        #expect(model.previewMessage == VoicesText.failure(.microphoneBusy))
        #expect(model.listeningRow == nil)
        await settle()
        #expect(rig.factory.calls.isEmpty)
    }

    /// C2 : la ligne écoutée, pendant la préparation et la lecture ; `nil` après la fin, après une panne, après un arrêt ; une
    /// seconde écoute sur une autre ligne la remplace.
    @Test func theListeningRowFollowsTheListening() async {
        let gate = TestGate()
        defer { gate.open() }
        let player = ScriptedClipPlayer(completion: .manual)
        let unusable = Self.saved(
            "Voix d'exemple C", id: 3, provider: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff"))
        let rig = Rig(
            Self.settings(voices: [unusable]), systemVoice: PreviewVoice(.held(gate, VoicePreviewTests.clip)), player: player)
        let model = rig.model
        let rowA = RowID.system(identifier: "voix.exemple.a")
        let rowB = RowID.system(identifier: "voix.exemple.b")
        #expect(model.listeningRow == nil)
        model.selection = rowA
        model.listen()
        #expect(model.previewState == .preparing)
        #expect(model.listeningRow == rowA, "pendant la préparation")
        gate.open()
        #expect(await until { player.isPlaying })
        #expect(model.previewState == .playing)
        #expect(model.listeningRow == rowA, "pendant la lecture")

        model.selection = rowB
        model.listen()
        #expect(model.listeningRow == rowB, "une seconde écoute remplace la première")
        #expect(await until { player.clips.count == 2 && player.isPlaying })
        player.finish()
        #expect(await until { model.previewState == .idle })
        #expect(model.listeningRow == nil, "après la fin")

        model.listen()
        #expect(model.listeningRow == rowB)
        model.stopListening()
        #expect(model.listeningRow == nil, "après un arrêt")

        model.selection = .saved(unusable.id)
        model.listen()
        #expect(model.listeningRow == .saved(unusable.id))
        #expect(await until { model.previewState == .failed(.unusable(.providerRemoved)) })
        #expect(model.listeningRow == nil, "après une panne")
    }

    /// C3 : un filtre qui cache la ligne choisie la désélectionne et arrête l'écoute ; un geste ne vise jamais une ligne
    /// invisible.
    @Test func aSelectionHiddenByTheFiltersIsDroppedAndNoGestureReachesIt() async {
        let gate = TestGate()
        defer { gate.open() }
        let saved = Self.saved("Voix d'exemple A", id: 1, language: "en-US")
        let rig = Rig(Self.settings(voices: [saved]), systemVoice: PreviewVoice(.held(gate, VoicePreviewTests.clip)))
        let model = rig.model
        model.language = nil
        model.selection = RowID.system(identifier: "voix.exemple.b")
        model.listen()
        #expect(model.listeningRow == RowID.system(identifier: "voix.exemple.b"))
        #expect(await until { rig.factory.system.texts.count == 1 }, "la synthèse est en cours (retenue par la porte)")
        model.gender = .female
        #expect(model.selection == nil, "la ligne cachée n'est plus choisie")
        #expect(model.selectedRow == nil)
        #expect(model.previewState == .idle, "l'écoute est arrêtée")
        #expect(model.listeningRow == nil)
        // L'écoute elle-même est arrêtée (pas seulement l'affichage) : la synthèse retenue a vu l'annulation et rien n'est joué.
        gate.open()
        #expect(await until { rig.factory.system.sawCancellation })
        await settle()
        #expect(rig.player.clips.isEmpty, "l'écoute arrêtée n'a rien joué")
        #expect(model.previewState == .idle)

        // Une ligne choisie alors qu'elle est cachée : aucun geste ne l'atteint.
        model.gender = .all
        model.language = "fr-FR"
        model.selection = .saved(saved.id)
        #expect(model.selectedRow == nil)
        #expect(!model.canUse && !model.canListen && !model.canDelete && !model.canEdit)
        model.use()
        model.listen()
        model.requestDeletion()
        #expect(rig.updates == 0)
        #expect(model.pendingDeletion == nil)
        #expect(model.listeningRow == nil)
        #expect(rig.factory.calls.count == 1, "seule la première écoute a fabriqué une voix")

        // Un filtre qui garde la ligne choisie ne la lâche pas.
        model.language = nil
        model.selection = .saved(saved.id)
        model.gender = .unspecified
        #expect(model.selection == .saved(saved.id))
    }

    /// C4 : la langue en cours du filtre est toujours proposée, même si aucune voix ne la porte plus.
    @Test func theCurrentLanguageIsAlwaysOffered() {
        let rig = Rig(Self.settings(voice: VoiceChoice(language: "de-DE")))
        let model = rig.model
        #expect(model.language == "de-DE")
        #expect(model.languages.contains("de-DE"))
        #expect(model.languages == ["de-DE", "en-US", "fr-FR"])
        model.language = "it-IT"
        #expect(model.languages == ["en-US", "fr-FR", "it-IT"])
        model.language = nil
        #expect(model.languages == ["en-US", "fr-FR"])
    }

    /// C5 : la note de vie privée et l'écoute décident sur le même instantané. Le fournisseur de la voix choisie est retiré des
    /// réglages sans `reload()` : après `listen()`, la note et l'état disent tous deux que la voix ne peut pas parler, et rien n'est
    /// envoyé ni lu. `use()` relit de même avant d'écrire.
    @Test func thePrivacyNoteAndTheListeningShareOneSnapshot() async {
        let saved = Self.saved("Voix d'exemple A", id: 1)
        let rig = Rig(Self.settings(voices: [saved]))
        let model = rig.model
        model.selection = .saved(saved.id)
        #expect(model.privacyText == VoicesText.privacyProvider("Fournisseur d'exemple"))
        rig.settings.providers.removeAll { $0.id == Self.provider.id }
        model.listen()
        #expect(await until { model.previewState == .failed(.unusable(.providerRemoved)) })
        #expect(model.privacyText == VoicesText.privacyCannotSpeak)
        #expect(rig.keys.readCount == 0)
        #expect(!model.canUse)

        // `use()` relit : une voix enregistrée supprimée ailleurs (encore dans l'affichage) n'est pas réécrite en voix en vigueur.
        let other = Self.saved("Voix d'exemple B", id: 2)
        rig.settings = Self.settings(voices: [other])
        model.reload()
        model.selection = .saved(other.id)
        #expect(model.canUse)
        rig.settings.voices = []
        model.use()
        #expect(rig.updates == 0, "relu avant d'écrire : la ligne n'existe plus")
    }

    // MARK: - Tâche 4, tour de correction 1 : ce que la liste dit (C1 à C5)

    /// C1 : la langue en clair, par une locale française FIXE. Pas d'égalité sur la chaîne entière du système (elle peut changer
    /// d'une version à l'autre) : on tient ce qui doit y être, et ce qui distingue.
    @Test func aLanguageCodeIsNamedInPlainFrench() {
        #expect(VoicesText.languageName("fr-FR").contains("français"))
        #expect(VoicesText.languageName("en-US").contains("anglais"))
        #expect(VoicesText.languageName("fr-FR") != "fr-FR", "un code connu n'est pas rendu tel quel")
        // Deux codes d'une même langue : deux libellés différents (le filtre doit pouvoir les distinguer).
        #expect(VoicesText.languageName("fr-FR") != VoicesText.languageName("fr-CA"))
        #expect(VoicesText.languageName("fr-CA").contains("français"))
        // Un code inventé, vide ou blanc : rendu tel quel.
        for code in ["zz-ZZ", "code-invente", "", "  "] {
            #expect(VoicesText.languageName(code) == code, "« \(code) »")
        }
    }

    /// C1 et C2 : chaque ligne de détail dit la langue en clair, jamais le code ; une voix de fournisseur la dit aussi, après son
    /// fournisseur et son modèle. Une langue inventée reste son code (rien d'autre à montrer).
    @Test func everyDetailLineSaysTheLanguageInPlainWords() {
        let saved = Self.saved("Voix d'exemple A", id: 1, language: "en-US")
        let invented = Self.saved("Voix d'exemple B", id: 2, language: "zz-ZZ")
        let rig = Rig(Self.settings(voices: [saved, invented], voice: VoiceChoice(identifier: "voix.exemple.absente", language: "fr-FR")))
        let model = rig.model
        model.language = nil
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        let french = VoicesText.languageName("fr-FR")
        let english = VoicesText.languageName("en-US")
        for id: RowID in [.automatic(language: "fr-FR"), .system(identifier: "voix.exemple.a"), .active] {
            let detail = rows[id]?.detail ?? ""
            #expect(detail.hasPrefix(french), "\(id) : \(detail)")
            #expect(!detail.contains("fr-FR"), "\(id) : pas de code (\(detail))")
        }
        #expect(rows[.automatic(language: "en-US")]?.detail.hasPrefix(english) == true)
        #expect(rows[.saved(saved.id)]?.detail == "Fournisseur d'exemple · modele-voix-exemple · \(english)")
        #expect(rows[.saved(invented.id)]?.detail == "Fournisseur d'exemple · modele-voix-exemple · zz-ZZ")
    }

    /// C3 : « Utiliser cette voix » est inactif sur la ligne cochée (la voix déjà en vigueur), et `use()` n'y écrit rien ; une
    /// autre ligne reste utilisable, et le devient de nouveau dès qu'elle n'est plus en vigueur.
    @Test func theVoiceInForceCannotBeUsedAgain() {
        let saved = Self.saved("Voix d'exemple A", id: 1)
        let rig = Rig(Self.settings(voices: [saved], voice: VoiceChoice(identifier: "voix.exemple.b", language: "fr-FR")))
        let model = rig.model
        let rowB = RowID.system(identifier: "voix.exemple.b")
        let rowA = RowID.system(identifier: "voix.exemple.a")
        model.selection = rowB
        #expect(model.selectedRow?.isActive == true)
        #expect(model.selectedRow?.canUse == false)
        #expect(!model.canUse)
        model.use()
        #expect(rig.updates == 0, "rien n'est écrit sur la voix déjà en vigueur")

        model.selection = rowA
        #expect(model.canUse)
        model.use()
        #expect(rig.updates == 1)
        #expect(!model.canUse, "A est maintenant la voix en vigueur")
        model.selection = rowB
        #expect(model.canUse, "B ne l'est plus")

        // Une voix enregistrée en vigueur, de même.
        model.selection = .saved(saved.id)
        model.use()
        #expect(model.selectedRow?.isActive == true)
        #expect(!model.canUse)
    }

    /// Ce qui doit effacer une panne d'écoute affichée (C4).
    enum StaleFailureTrigger: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case selection, languageFilter, genderFilter, use, save, confirmedDeletion
        var testDescription: String { rawValue }
    }

    /// C4 : une panne d'écoute ancienne ne reste pas affichée. La panne (micro tenu, refus immédiat de l'écoute) est d'abord vue
    /// affichée ; puis un seul déclencheur, qui ne cache pas la ligne choisie (sinon c'est l'arrêt d'une ligne cachée qui
    /// efface, déjà tenu ailleurs) : l'état revient à `.idle` et la phrase disparaît.
    @Test(arguments: StaleFailureTrigger.allCases)
    func aStaleListeningFailureIsClearedBy(_ trigger: StaleFailureTrigger) {
        let saved = Self.saved("Voix d'exemple D", id: 1, gender: .female)
        let rig = Rig(Self.settings(voices: [saved]))
        let model = rig.model
        let rowA = RowID.system(identifier: "voix.exemple.a")  // féminine, fr-FR
        model.selection = trigger == .confirmedDeletion ? .saved(saved.id) : rowA
        rig.microphone.held = true
        model.listen()
        rig.microphone.held = false
        #expect(model.previewState == .failed(.microphoneBusy), "témoin : la panne est affichée")
        #expect(model.previewMessage != nil)

        switch trigger {
        case .selection:
            model.selection = RowID.system(identifier: "voix.exemple.b")
        case .languageFilter:
            model.language = nil
            #expect(model.selection == rowA, "la ligne choisie reste montrée")
        case .genderFilter:
            model.gender = .female
            #expect(model.selection == rowA, "la ligne choisie reste montrée")
        case .use:
            model.use()
            #expect(rig.updates == 1)
        case .save:
            model.beginAdding()
            model.draft = Self.validDraft()
            model.save()
            #expect(rig.updates == 1)
        case .confirmedDeletion:
            model.requestDeletion()
            model.confirmDeletion()
            #expect(rig.updates == 1)
        }
        #expect(model.previewState == .idle, "\(trigger)")
        #expect(model.previewMessage == nil, "\(trigger)")
    }

    /// C4 : un geste REFUSÉ n'efface pas la panne (seul un geste réussi le fait) : sans ce témoin, un effacement à chaque appel
    /// passerait le test précédent.
    @Test func aRefusedGestureKeepsTheListeningFailure() {
        let rig = Rig(Self.settings())
        let model = rig.model
        model.selection = RowID.system(identifier: "voix.exemple.a")
        rig.microphone.held = true
        model.listen()
        rig.microphone.held = false
        model.beginAdding()
        model.save()  // sans nom : refusé
        model.draft = nil
        rig.failure = ForeignError()
        model.use()  // écriture refusée
        #expect(rig.updates == 1)
        #expect(model.previewState == .failed(.microphoneBusy))
    }

    /// C4 : une écoute EN COURS n'est pas touchée par un changement de sélection (« Arrêter » reste là), ni par un filtre qui
    /// garde la ligne choisie.
    @Test func aListeningInProgressSurvivesASelectionChange() async {
        let gate = TestGate()
        defer { gate.open() }
        let rig = Rig(Self.settings(), systemVoice: PreviewVoice(.held(gate, VoicePreviewTests.clip)))
        let model = rig.model
        let rowA = RowID.system(identifier: "voix.exemple.a")
        model.selection = rowA
        model.listen()
        #expect(model.previewState == .preparing)
        model.selection = RowID.system(identifier: "voix.exemple.b")
        #expect(model.previewState == .preparing)
        #expect(model.listeningRow == rowA)
        #expect(VoicesPane.listenButton(listeningRow: model.listeningRow, state: model.previewState, canListen: model.canListen).stops)
        model.language = nil
        #expect(model.previewState == .preparing)
        #expect(model.listeningRow == rowA)
        model.stopListening()
    }

    /// C5 : la confirmation nomme la voix ; si c'est la voix en vigueur (la ligne cochée), une seconde phrase dit que Supervox
    /// reprendra la voix du système. La jumelle non cochée de la voix en vigueur n'a pas cette phrase.
    @Test func theConfirmationNamesTheVoiceAndSaysWhenItIsInForce() {
        let first = Self.saved("Voix d'exemple A", id: 1)
        let twin = Self.saved("Voix d'exemple B", id: 2)
        let rig = Rig(Self.settings(voices: [first, twin], voice: first.voice))
        let model = rig.model
        model.selection = .saved(twin.id)
        model.requestDeletion()
        #expect(model.confirmationText == InterviewText.fr("Supprimer la voix « Voix d'exemple B » ?"))
        model.cancelConfirmation()

        model.selection = .saved(first.id)
        model.requestDeletion()
        let active = model.confirmationText ?? ""
        #expect(active.hasPrefix(InterviewText.fr("Supprimer la voix « Voix d'exemple A » ?")))
        #expect(active == VoicesText.deleteConfirmation(name: "Voix d'exemple A", isActive: true))
        #expect(active.contains("voix automatique du système"), "\(active)")
        #expect(VoicesText.deleteConfirmation(name: "Voix d'exemple A", isActive: false).count < active.count)
    }
}
