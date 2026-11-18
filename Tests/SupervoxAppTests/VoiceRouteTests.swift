import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Les règles qui lisent une voix (tâche 2) : sa forme normalisée (règle 3), qui parle vraiment (`route(in:)`, règle 4, et les deux
/// lecteurs qui passent par elle), et « cette ligne est la voix en vigueur » (`isSameVoice`, règle 6). Aucun réseau, aucun trousseau
/// réel, aucune voix du système : des doubles.
@Suite(.timeLimit(.minutes(1))) struct VoiceRouteTests {
    static let speakingID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0B1")!
    static let silentID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0B2")!
    static let goneID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0B3")!

    /// Un fournisseur au format OpenAI (il a une synthèse) et un au format Anthropic (il n'en a pas).
    static let speaking = Provider(
        id: speakingID, name: "Fournisseur d'exemple", baseURL: "https://example.com/v1", kind: .openAICompatible,
        models: ["modele-exemple"])
    static let silent = Provider(
        id: silentID, name: "Fournisseur d'exemple sans voix", baseURL: "https://example.com/autre", kind: .anthropic,
        models: ["modele-exemple"])

    static let modelsID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0B4")!
    /// Le fournisseur des deux modèles, distinct de ceux de la voix : sa clé est lue pour les modèles, jamais celles des autres
    /// pour rien, et un lecteur qui nommerait le fournisseur des modèles à la place de celui de la voix se verrait.
    static let models = Provider(
        id: modelsID, name: "Second d'exemple", baseURL: "https://example.com/modeles", kind: .openAICompatible,
        models: ["modele-exemple"])

    static var settings: AppSettings {
        var settings = AppSettings.defaults
        settings.providers = [speaking, silent, models]
        settings.fastModel = ModelChoice(providerID: modelsID, model: "modele-exemple")
        settings.strongModel = ModelChoice(providerID: modelsID, model: "modele-exemple")
        return settings
    }

    /// Une voix de fournisseur complète.
    static let providerVoice = VoiceChoice(
        providerID: speakingID, model: "modele-voix-exemple", identifier: "voix-exemple", language: "fr-CA", gender: .female,
        extra: ["cle-exemple": "valeur-exemple"])

    static func decode(_ json: String) throws -> VoiceChoice {
        try JSONDecoder().decode(VoiceChoice.self, from: Data(json.utf8))
    }

    // MARK: - Règle 3 : la forme normalisée

    struct NormalizedCase: Sendable, CustomTestStringConvertible {
        let name: String
        let input: VoiceChoice
        let expected: VoiceChoice
        var testDescription: String { name }
    }

    static let sixteenKeys = (1...16).map { String(format: "cle-exemple-%02d", $0) }

    static let normalizedCases: [NormalizedCase] = [
        NormalizedCase(
            name: "clés réservées retirées",
            input: VoiceChoice(extra: [
                "model": "x", "input": "x", "voice": "x", "response_format": "mp3", "cle-exemple": "valeur-exemple",
            ]),
            expected: VoiceChoice(extra: ["cle-exemple": "valeur-exemple"])),
        NormalizedCase(
            name: "clé réservée entourée d'espaces",
            input: VoiceChoice(extra: [" model ": "x", "voice\n": "x", "cle-exemple": "valeur-exemple"]),
            expected: VoiceChoice(extra: ["cle-exemple": "valeur-exemple"])),
        NormalizedCase(
            name: "clés réservées comparées sans casse",
            input: VoiceChoice(extra: [
                "Model": "x", "VOICE": "x", " Input ": "x", "Response_Format": "x", "cle-exemple": "valeur-exemple",
            ]),
            expected: VoiceChoice(extra: ["cle-exemple": "valeur-exemple"])),
        NormalizedCase(
            name: "clés vides ou blanches retirées",
            input: VoiceChoice(extra: ["": "x", "   ": "y", "cle-exemple": "valeur-exemple"]),
            expected: VoiceChoice(extra: ["cle-exemple": "valeur-exemple"])),
        NormalizedCase(
            name: "clés rognées, valeurs intactes",
            input: VoiceChoice(extra: [" cle-exemple ": " valeur-exemple "]),
            expected: VoiceChoice(extra: ["cle-exemple": " valeur-exemple "])),
        NormalizedCase(
            name: "deux clés qui se rejoignent : la clé déjà propre l'emporte",
            input: VoiceChoice(extra: [" cle-exemple": "rognee", "cle-exemple": "propre"]),
            expected: VoiceChoice(extra: ["cle-exemple": "propre"])),
        NormalizedCase(
            name: "deux clés rognées qui se rejoignent : la première dans l'ordre des clés d'origine",
            input: VoiceChoice(extra: ["cle-exemple ": "apres", " cle-exemple": "avant"]),
            expected: VoiceChoice(extra: ["cle-exemple": "avant"])),
        NormalizedCase(
            name: "17 entrées : les 16 premières dans l'ordre des clés",
            input: VoiceChoice(extra: Dictionary(uniqueKeysWithValues: (1...17).map { (String(format: "cle-exemple-%02d", $0), "v") })),
            expected: VoiceChoice(extra: Dictionary(uniqueKeysWithValues: sixteenKeys.map { ($0, "v") }))),
        NormalizedCase(
            name: "16 entrées et des clés retirées : les retirées ne comptent pas dans les 16",
            input: VoiceChoice(
                extra: Dictionary(uniqueKeysWithValues: sixteenKeys.map { ($0, "v") }).merging(["": "x", " ": "y", "input": "z"]) { a, _ in a }),
            expected: VoiceChoice(extra: Dictionary(uniqueKeysWithValues: sixteenKeys.map { ($0, "v") }))),
        NormalizedCase(
            name: "modèle et identifiant blancs : nil",
            input: VoiceChoice(providerID: speakingID, model: "  ", identifier: "\n"),
            expected: VoiceChoice(providerID: speakingID, model: nil, identifier: nil)),
        NormalizedCase(
            name: "modèle et identifiant vides : nil",
            input: VoiceChoice(providerID: speakingID, model: "", identifier: ""),
            expected: VoiceChoice(providerID: speakingID, model: nil, identifier: nil)),
        NormalizedCase(
            name: "modèle et identifiant rognés",
            input: VoiceChoice(providerID: speakingID, model: " modele-voix-exemple ", identifier: "\tvoix-exemple "),
            expected: VoiceChoice(providerID: speakingID, model: "modele-voix-exemple", identifier: "voix-exemple")),
        NormalizedCase(
            name: "langue vide ou blanche : fr-FR",
            input: VoiceChoice(language: "  "),
            expected: VoiceChoice(language: "fr-FR")),
        NormalizedCase(
            name: "langue vide : fr-FR",
            input: VoiceChoice(language: ""),
            expected: VoiceChoice(language: "fr-FR")),
        NormalizedCase(
            name: "langue rognée (espaces et retours)",
            input: VoiceChoice(language: " fr-CA\n"),
            expected: VoiceChoice(language: "fr-CA")),
        NormalizedCase(
            name: "une langue qui dit quelque chose ne change pas",
            input: VoiceChoice(language: "fr-CA"),
            expected: VoiceChoice(language: "fr-CA")),
        NormalizedCase(
            name: "fournisseur, genre et le reste ne bougent pas",
            input: providerVoice,
            expected: providerVoice),
    ]

    @Test(arguments: normalizedCases)
    func theNormalizedFormHasItsTable(_ example: NormalizedCase) {
        let normalized = example.input.normalized
        #expect(normalized == example.expected)
        #expect(normalized.extra.count <= VoiceChoice.maxExtraEntries)
        #expect(normalized.normalized == normalized, "idempotente")
        #expect(normalized.gender == example.input.gender && normalized.providerID == example.input.providerID)
    }

    @Test func theNormalizedFormKeepsUnknownFieldsAndTheLimitsAreTheBriefs() throws {
        #expect(VoiceChoice.reservedExtraKeys == ["model", "input", "voice", "response_format"])
        #expect(VoiceChoice.maxExtraEntries == 16)
        let read = try Self.decode(#"{"language":"fr-FR","model":" modele-voix-exemple ","nuance":"douce"}"#)
        let written = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(read.normalized))
        guard case .object(let object) = written else { Issue.record("pas un objet"); return }
        #expect(object["nuance"] == .string("douce"))
        #expect(object["model"] == .string("modele-voix-exemple"))
    }

    // MARK: - Règle 4 : qui parle vraiment

    struct RouteCase: Sendable, CustomTestStringConvertible {
        let name: String
        let choice: VoiceChoice
        let expected: VoiceRoute
        var testDescription: String { name }
    }

    static func with(_ change: (inout VoiceChoice) -> Void) -> VoiceChoice {
        var choice = providerVoice
        change(&choice)
        return choice
    }

    static let routeCases: [RouteCase] = [
        RouteCase(
            name: "sans fournisseur : le système, langue et identifiant du choix",
            choice: VoiceChoice(identifier: "voix.exemple.a", language: "fr-CA"),
            expected: .system(language: "fr-CA", identifier: "voix.exemple.a", because: nil)),
        RouteCase(
            name: "sans fournisseur, identifiant blanc et langue vide : la meilleure voix en fr-FR",
            choice: VoiceChoice(identifier: "  ", language: ""),
            expected: .system(language: "fr-FR", identifier: nil, because: nil)),
        RouteCase(
            name: "sans fournisseur, un modèle laissé là ne compte pas",
            choice: VoiceChoice(model: "modele-voix-exemple", identifier: "voix.exemple.a"),
            expected: .system(language: "fr-FR", identifier: "voix.exemple.a", because: nil)),
        RouteCase(
            name: "fournisseur supprimé",
            choice: with { $0.providerID = goneID },
            expected: .system(language: "fr-CA", identifier: nil, because: .providerRemoved)),
        RouteCase(
            name: "fournisseur supprimé et modèle blanc : supprimé d'abord",
            choice: with {
                $0.providerID = goneID
                $0.model = " "
            },
            expected: .system(language: "fr-CA", identifier: nil, because: .providerRemoved)),
        RouteCase(
            name: "fournisseur sans synthèse",
            choice: with { $0.providerID = silentID },
            expected: .system(language: "fr-CA", identifier: nil, because: .providerCannotSpeak)),
        RouteCase(
            name: "fournisseur sans synthèse et identifiant blanc : sans synthèse d'abord",
            choice: with {
                $0.providerID = silentID
                $0.identifier = ""
            },
            expected: .system(language: "fr-CA", identifier: nil, because: .providerCannotSpeak)),
        RouteCase(
            name: "modèle blanc", choice: with { $0.model = "  " },
            expected: .system(language: "fr-CA", identifier: nil, because: .incomplete)),
        RouteCase(
            name: "modèle absent", choice: with { $0.model = nil },
            expected: .system(language: "fr-CA", identifier: nil, because: .incomplete)),
        RouteCase(
            name: "identifiant blanc", choice: with { $0.identifier = "\n" },
            expected: .system(language: "fr-CA", identifier: nil, because: .incomplete)),
        RouteCase(
            name: "identifiant absent", choice: with { $0.identifier = nil },
            expected: .system(language: "fr-CA", identifier: nil, because: .incomplete)),
        RouteCase(
            name: "repli : langue vide du choix lue fr-FR",
            choice: with {
                $0.providerID = goneID
                $0.language = " "
            },
            expected: .system(language: "fr-FR", identifier: nil, because: .providerRemoved)),
        RouteCase(
            name: "voix complète : le fournisseur",
            choice: providerVoice,
            expected: .provider(
                speaking,
                ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["cle-exemple": "valeur-exemple"]))),
        RouteCase(
            name: "voix complète écrite à la main : rognée, sans clé réservée",
            choice: with {
                $0.model = " modele-voix-exemple "
                $0.identifier = " voix-exemple"
                $0.extra = ["model": "x", " cle-exemple ": "valeur-exemple", "": "y"]
            },
            expected: .provider(
                speaking,
                ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["cle-exemple": "valeur-exemple"]))),
    ]

    @Test(arguments: routeCases)
    func theRouteHasItsTable(_ example: RouteCase) {
        #expect(example.choice.route(in: Self.settings) == example.expected)
    }

    /// Les cas de `everyReaderAgreesOnWhoSpeaks` : un par issue de `route(in:)`.
    enum Who: String, CaseIterable, Sendable {
        case system, providerRemoved, providerCannotSpeak, incompleteModel, incompleteIdentifier, provider

        var choice: VoiceChoice {
            switch self {
            case .system: VoiceChoice(identifier: "voix.exemple.a", language: "fr-CA")
            case .providerRemoved: VoiceRouteTests.with { $0.providerID = VoiceRouteTests.goneID }
            case .providerCannotSpeak: VoiceRouteTests.with { $0.providerID = VoiceRouteTests.silentID }
            case .incompleteModel: VoiceRouteTests.with { $0.model = " " }
            case .incompleteIdentifier: VoiceRouteTests.with { $0.identifier = nil }
            case .provider: VoiceRouteTests.providerVoice
            }
        }
    }

    /// Les trois lecteurs (`route(in:)`, la résolution de l'entretien, la ligne de vie privée de l'onglet) reçoivent la même voix et
    /// disent la même chose : un fournisseur n'est nommé, et sa voix fabriquée, que pour `.provider`. Toutes les clés sont dans le
    /// trousseau double : seule la règle décide.
    @MainActor
    @Test(arguments: Who.allCases)
    func everyReaderAgreesOnWhoSpeaks(_ who: Who) async throws {
        var settings = Self.settings
        settings.voice = who.choice
        let route = settings.voice.route(in: settings)
        let speaks: Bool
        if case .provider = route { speaks = true } else { speaks = false }
        #expect(speaks == (who == .provider), "route(in:) : \(route)")

        let store = SetupAccountStore(keys: [
            Self.speakingID: "cle-exemple", Self.silentID: "cle-exemple", Self.modelsID: "cle-exemple",
        ])
        let voices = SetupVoiceFactory()
        let setup = try await InterviewSetup.resolve(
            settings: settings, engine: nil, secrets: SecretAccess(store, queue: DispatchQueue(label: "test.route.\(UUID())")),
            makeModel: { _, _ in ScriptedModel(.never) }, makeVoice: voices.make)
        // Le fournisseur NOMMÉ est celui de la voix, jamais celui des modèles ni celui qui n'a pas de synthèse.
        let voiceName: String? = speaks ? "Fournisseur d'exemple" : nil
        #expect(setup.voiceProviderName == voiceName, "résolution")
        #expect(voices.calls.compactMap(\.providerName) == (speaks ? ["Fournisseur d'exemple"] : []), "voix de fournisseur fabriquée")
        let sentFromVoice = "Le texte que dit Supervox part chez «\u{00A0}Fournisseur d'exemple\u{00A0}»."
        #expect(speaks ? setup.privacy.hasSuffix(sentFromVoice) : !setup.privacy.contains("Le texte que dit Supervox"), "\(setup.privacy)")
        // La clé de la voix n'est lue que pour une voix qui parle ; jamais celle du fournisseur sans synthèse.
        let voiceKeysRead = Set(store.readAccounts).intersection([Self.speakingID.uuidString, Self.silentID.uuidString])
        #expect(voiceKeysRead == (speaks ? [Self.speakingID.uuidString] : []), "clés lues : \(store.readAccounts)")

        let privacy = InterviewSettingsModelTests.Rig(settings).makeModel().privacyText
        let named =
            "Le texte de vos réponses est envoyé au fournisseur du modèle rapide et du modèle fort\u{00A0}; l'audio du micro ne quitte jamais cet ordinateur. La voix de Supervox vient de «\u{00A0}Fournisseur d'exemple\u{00A0}»\u{00A0}: le texte qu'elle dit lui est envoyé."
        #expect(privacy == (speaks ? named : InterviewSettingsModelTests.systemPrivacy), "onglet : \(privacy)")
    }

    // MARK: - Point 1 du tour de correction : une seule construction de `ProviderVoice`, une seule résolution

    struct ProviderVoiceCase: Sendable, CustomTestStringConvertible {
        let name: String
        let choice: VoiceChoice
        let expected: ProviderVoice?
        var testDescription: String { name }
    }

    static let providerVoiceCases: [ProviderVoiceCase] = [
        ProviderVoiceCase(name: "voix du système", choice: VoiceChoice(identifier: "voix.exemple.a"), expected: nil),
        ProviderVoiceCase(
            name: "sans fournisseur, même avec modèle et identifiant",
            choice: VoiceChoice(model: "modele-voix-exemple", identifier: "voix-exemple"), expected: nil),
        ProviderVoiceCase(name: "modèle blanc", choice: with { $0.model = " " }, expected: nil),
        ProviderVoiceCase(name: "identifiant absent", choice: with { $0.identifier = nil }, expected: nil),
        ProviderVoiceCase(
            name: "voix complète",
            choice: providerVoice,
            expected: ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["cle-exemple": "valeur-exemple"])),
        ProviderVoiceCase(
            name: "écrite à la main : rognée, sans clé réservée ni clé vide",
            choice: with {
                $0.model = "\tmodele-voix-exemple "
                $0.identifier = " voix-exemple"
                $0.extra = ["model": "x", "Voice": "x", "": "x", " cle-exemple ": "valeur-exemple"]
            },
            expected: ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["cle-exemple": "valeur-exemple"])),
        ProviderVoiceCase(
            name: "fournisseur supprimé : la voix se construit (les réglages ne sont pas lus ici)",
            choice: with { $0.providerID = goneID },
            expected: ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["cle-exemple": "valeur-exemple"])),
    ]

    @Test(arguments: providerVoiceCases)
    func theProviderVoiceHasItsTable(_ example: ProviderVoiceCase) {
        #expect(example.choice.providerVoice == example.expected)
    }

    /// Ce qu'une résolution rend, sous une forme comparable (`ResolvedProvider` ne se compare pas : il porte la clé).
    enum Resolved: Equatable {
        case system(language: String, identifier: String?, because: SystemReason?)
        case provider(name: String, baseURL: URL, apiKey: String, voice: ProviderVoice)

        init(_ resolved: ResolvedVoice) {
            switch resolved {
            case .system(let language, let identifier, let because):
                self = Resolved.system(language: language, identifier: identifier, because: because)
            case .provider(let provider, let voice):
                self = .provider(
                    name: provider.name, baseURL: provider.config.baseURL, apiKey: provider.config.apiKey, voice: voice)
            }
        }
    }

    /// `resolve(in:secrets:)` : la route, puis la clé pour `.provider` seulement. Aucune clé n'est lue pour une voix du système ou
    /// une voix inutilisable (le trousseau double note chaque compte lu).
    @MainActor
    @Test(arguments: Who.allCases)
    func theResolutionReadsTheKeyOnlyForAProviderVoice(_ who: Who) async throws {
        let settings = Self.settings
        let store = SetupAccountStore(keys: [
            Self.speakingID: "cle-exemple", Self.silentID: "cle-exemple", Self.modelsID: "cle-exemple",
        ])
        let resolved = try await who.choice.resolve(
            in: settings, secrets: SecretAccess(store, queue: DispatchQueue(label: "test.resolve.\(UUID())")))
        let expected: Resolved =
            switch who {
            case .system: .system(language: "fr-CA", identifier: "voix.exemple.a", because: nil)
            case .providerRemoved: .system(language: "fr-CA", identifier: nil, because: .providerRemoved)
            case .providerCannotSpeak: .system(language: "fr-CA", identifier: nil, because: .providerCannotSpeak)
            case .incompleteModel, .incompleteIdentifier: .system(language: "fr-CA", identifier: nil, because: .incomplete)
            case .provider:
                .provider(
                    name: "Fournisseur d'exemple", baseURL: URL(string: "https://example.com/v1")!, apiKey: "cle-exemple",
                    voice: ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["cle-exemple": "valeur-exemple"]))
            }
        #expect(Resolved(resolved) == expected)
        #expect(store.readAccounts == (who == .provider ? [Self.speakingID.uuidString] : []), "comptes lus")
    }

    /// Une résolution qui échoue lève la `RewriteFailure` telle quelle (l'entretien, lui, retombe sur le système).
    @MainActor
    @Test func aFailedResolutionThrowsItsRewriteFailure() async throws {
        let missing = SetupAccountStore(keys: [Self.modelsID: "cle-exemple"])
        await #expect(throws: RewriteFailure.noKey(provider: "Fournisseur d'exemple")) {
            _ = try await Self.providerVoice.resolve(
                in: Self.settings, secrets: SecretAccess(missing, queue: DispatchQueue(label: "test.resolve.\(UUID())")))
        }
        let denied = SetupAccountStore(keys: [Self.speakingID: "cle-exemple"], denied: [Self.speakingID])
        await #expect(throws: RewriteFailure.keychain) {
            _ = try await Self.providerVoice.resolve(
                in: Self.settings, secrets: SecretAccess(denied, queue: DispatchQueue(label: "test.resolve.\(UUID())")))
        }
        var badAddress = Self.settings
        badAddress.providers[0].baseURL = "pas une adresse"
        let store = SetupAccountStore(keys: [Self.speakingID: "cle-exemple"])
        await #expect(throws: RewriteFailure.unreachable) {
            _ = try await Self.providerVoice.resolve(
                in: badAddress, secrets: SecretAccess(store, queue: DispatchQueue(label: "test.resolve.\(UUID())")))
        }
        #expect(store.readAccounts.isEmpty, "une adresse refusée ne coûte pas une lecture du trousseau")
    }

    /// Une tâche déjà annulée : la résolution d'une voix de fournisseur lève l'annulation sans lire le trousseau.
    @MainActor
    @Test func aCancelledResolutionThrowsCancellation() async throws {
        let store = SetupAccountStore(keys: [Self.speakingID: "cle-exemple"])
        let access = SecretAccess(store, queue: DispatchQueue(label: "test.resolve.\(UUID())"))
        let settings = Self.settings
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.providerVoice.resolve(in: settings, secrets: access)
        }
        // L'attente rend la main à l'annulation du test : elle annule la tâche attendue.
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(store.readAccounts.isEmpty)
    }

    // MARK: - Règle 6 : la même voix

    struct SameCase: Sendable, CustomTestStringConvertible {
        let name: String
        let lhs: VoiceChoice
        let rhs: VoiceChoice
        let same: Bool
        var testDescription: String { name }
    }

    static let systemVoice = VoiceChoice(identifier: "voix.exemple.a", language: "fr-FR")

    static func system(_ change: (inout VoiceChoice) -> Void) -> VoiceChoice {
        var choice = systemVoice
        change(&choice)
        return choice
    }

    static let sameCases: [SameCase] = [
        SameCase(name: "fournisseur : mêmes six champs", lhs: providerVoice, rhs: providerVoice, same: true),
        SameCase(
            name: "fournisseur : un paramètre de plus", lhs: providerVoice,
            rhs: with { $0.extra["cle-exemple-2"] = "valeur-exemple" }, same: false),
        SameCase(name: "fournisseur : genre différent", lhs: providerVoice, rhs: with { $0.gender = .male }, same: false),
        SameCase(name: "fournisseur : genre absent", lhs: providerVoice, rhs: with { $0.gender = nil }, same: false),
        SameCase(name: "fournisseur : autre modèle", lhs: providerVoice, rhs: with { $0.model = "modele-exemple" }, same: false),
        SameCase(
            name: "fournisseur : autre identifiant", lhs: providerVoice, rhs: with { $0.identifier = "voix.exemple.a" }, same: false),
        SameCase(name: "fournisseur : autre langue", lhs: providerVoice, rhs: with { $0.language = "fr-FR" }, same: false),
        SameCase(name: "fournisseur : autre fournisseur", lhs: providerVoice, rhs: with { $0.providerID = silentID }, same: false),
        SameCase(
            name: "fournisseur : espaces autour du modèle (normalisation)", lhs: providerVoice,
            rhs: with { $0.model = "  modele-voix-exemple " }, same: true),
        SameCase(
            name: "fournisseur : clé réservée en plus (normalisation)", lhs: providerVoice,
            rhs: with { $0.extra["voice"] = "voix.exemple.a" }, same: true),
        // Deux voix du système qui ont un identifiant : l'identifiant seul décide.
        SameCase(
            name: "système : même identifiant, fr-FR contre fr_fr", lhs: systemVoice, rhs: system { $0.language = "fr_fr" },
            same: true),
        SameCase(
            name: "système : même identifiant, fr-FR contre fr-CA (l'identifiant décide)", lhs: systemVoice,
            rhs: system { $0.language = "fr-CA" }, same: true),
        SameCase(name: "système : même identifiant, genre différent", lhs: systemVoice, rhs: system { $0.gender = .male }, same: true),
        SameCase(
            name: "système : même identifiant, paramètres différents", lhs: systemVoice,
            rhs: system { $0.extra = ["cle-exemple": "valeur-exemple"] }, same: true),
        SameCase(
            name: "système : même identifiant aux espaces près (normalisation)", lhs: systemVoice,
            rhs: system { $0.identifier = " voix.exemple.a " }, same: true),
        SameCase(
            name: "système : autre identifiant, même langue", lhs: systemVoice, rhs: system { $0.identifier = "voix-exemple" },
            same: false),
        // L'une avec un identifiant, l'autre sans : jamais la même.
        SameCase(name: "système : identifiant nil contre un identifiant", lhs: systemVoice, rhs: system { $0.identifier = nil }, same: false),
        SameCase(
            name: "système : identifiant blanc contre un identifiant", lhs: system { $0.identifier = " " }, rhs: systemVoice,
            same: false),
        // Aucune n'a d'identifiant : la langue décide, sans casse, `_` et `-` confondus, rognée.
        SameCase(
            name: "système sans identifiant : même langue", lhs: system { $0.identifier = nil },
            rhs: system { $0.identifier = nil }, same: true),
        SameCase(
            name: "système sans identifiant : identifiant blanc et nil (normalisation)", lhs: system { $0.identifier = " " },
            rhs: system { $0.identifier = nil }, same: true),
        SameCase(
            name: "système sans identifiant : fr-FR contre FR_fr", lhs: system { $0.identifier = nil },
            rhs: system {
                $0.identifier = nil
                $0.language = "FR_fr"
            }, same: true),
        SameCase(
            name: "système sans identifiant : fr-FR contre une langue entourée d'espaces (rognée)", lhs: system { $0.identifier = nil },
            rhs: system {
                $0.identifier = nil
                $0.language = " fr-FR\n"
            }, same: true),
        SameCase(
            name: "système sans identifiant : fr-FR contre fr-CA", lhs: system { $0.identifier = nil },
            rhs: system {
                $0.identifier = nil
                $0.language = "fr-CA"
            }, same: false),
        SameCase(
            name: "système sans identifiant : fr-FR contre fr", lhs: system { $0.identifier = nil },
            rhs: system {
                $0.identifier = nil
                $0.language = "fr"
            }, same: false),
        SameCase(
            name: "système sans identifiant : genre différent", lhs: system { $0.identifier = nil },
            rhs: system {
                $0.identifier = nil
                $0.gender = .female
            }, same: true),
        SameCase(
            name: "système contre fournisseur, mêmes identifiant et langue", lhs: system { $0.identifier = "voix-exemple" },
            rhs: with {
                $0.identifier = "voix-exemple"
                $0.language = "fr-FR"
            }, same: false),
    ]

    @Test(arguments: sameCases)
    func theSameVoiceRuleHasItsTable(_ example: SameCase) {
        #expect(example.lhs.isSameVoice(as: example.rhs) == example.same)
        #expect(example.rhs.isSameVoice(as: example.lhs) == example.same, "symétrique")
    }

    /// `isSameVoice` est une relation d'équivalence sur toutes les voix de la table : réflexive, symétrique et transitive (chaque
    /// triplet est essayé).
    @Test func theSameVoiceRuleIsAnEquivalenceOnTheTable() {
        let voices = Self.sameCases.flatMap { [$0.lhs, $0.rhs] }
        for a in voices {
            #expect(a.isSameVoice(as: a), "réflexive : \(a)")
            for b in voices {
                #expect(a.isSameVoice(as: b) == b.isSameVoice(as: a), "symétrique : \(a) / \(b)")
                guard a.isSameVoice(as: b) else { continue }
                for c in voices where b.isSameVoice(as: c) {
                    #expect(a.isSameVoice(as: c), "transitive : \(a) / \(b) / \(c)")
                }
            }
        }
    }

    /// Un champ inconnu ne compte pas (fournisseur comme système).
    @Test func anUnknownFieldDoesNotMakeAnotherVoice() throws {
        let provider = try Self.decode(
            #"{"providerID":"00000000-0000-0000-0000-00000000D0B1","model":"modele-voix-exemple","identifier":"voix-exemple","language":"fr-CA","gender":"female","extra":{"cle-exemple":"valeur-exemple"},"nuance":"douce"}"#)
        #expect(provider.isSameVoice(as: Self.providerVoice))
        let system = try Self.decode(#"{"identifier":"voix.exemple.a","language":"fr-FR","nuance":"douce"}"#)
        #expect(system.isSameVoice(as: Self.systemVoice))
    }
}
