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

    static var settings: AppSettings {
        var settings = AppSettings.defaults
        settings.providers = [speaking, silent]
        settings.fastModel = ModelChoice(providerID: speakingID, model: "modele-exemple")
        settings.strongModel = ModelChoice(providerID: speakingID, model: "modele-exemple")
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
            name: "une clé réservée se compare telle quelle (casse comprise)",
            input: VoiceChoice(extra: ["Model": "x"]),
            expected: VoiceChoice(extra: ["Model": "x"])),
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

        let store = SetupAccountStore(keys: [Self.speakingID: "cle-exemple", Self.silentID: "cle-exemple"])
        let voices = SetupVoiceFactory()
        let setup = try await InterviewSetup.resolve(
            settings: settings, engine: nil, secrets: SecretAccess(store, queue: DispatchQueue(label: "test.route.\(UUID())")),
            makeModel: { _, _ in ScriptedModel(.never) }, makeVoice: voices.make)
        #expect((setup.voiceProviderName != nil) == speaks, "résolution : \(String(describing: setup.voiceProviderName))")
        #expect(voices.calls.contains { $0.providerName != nil } == speaks, "voix de fournisseur fabriquée")
        #expect(setup.privacy.contains("Le texte que dit Supervox part chez") == speaks)
        if !speaks {
            #expect(!store.readAccounts.contains(Self.silentID.uuidString), "aucune clé lue pour une voix qui ne parlera pas")
        }

        let privacy = InterviewSettingsModelTests.Rig(settings).makeModel().privacyText
        #expect((privacy != InterviewSettingsModelTests.systemPrivacy) == speaks, "onglet : \(privacy)")
        #expect(privacy.contains("Fournisseur d'exemple") == speaks)
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
        SameCase(
            name: "système : même identifiant, fr-FR contre fr_fr", lhs: systemVoice, rhs: system { $0.language = "fr_fr" },
            same: true),
        SameCase(
            name: "système : même identifiant, FR-fr", lhs: systemVoice, rhs: system { $0.language = "FR-fr" }, same: true),
        SameCase(name: "système : genre différent", lhs: systemVoice, rhs: system { $0.gender = .male }, same: true),
        SameCase(
            name: "système : paramètres différents", lhs: systemVoice, rhs: system { $0.extra = ["cle-exemple": "valeur-exemple"] },
            same: true),
        SameCase(name: "système : identifiant nil contre un identifiant", lhs: systemVoice, rhs: system { $0.identifier = nil }, same: false),
        SameCase(
            name: "système : deux identifiants nil, même langue", lhs: system { $0.identifier = nil },
            rhs: system { $0.identifier = nil }, same: true),
        SameCase(
            name: "système : identifiant blanc et nil (normalisation)", lhs: system { $0.identifier = " " },
            rhs: system { $0.identifier = nil }, same: true),
        SameCase(name: "système : autre identifiant", lhs: systemVoice, rhs: system { $0.identifier = "voix-exemple" }, same: false),
        SameCase(name: "système : fr-FR contre fr-CA", lhs: systemVoice, rhs: system { $0.language = "fr-CA" }, same: false),
        SameCase(name: "système : fr-FR contre fr", lhs: systemVoice, rhs: system { $0.language = "fr" }, same: false),
        SameCase(
            name: "système : fr-FR contre une langue entourée d'espaces (rien d'autre n'est confondu)", lhs: systemVoice,
            rhs: system { $0.language = " fr-FR" }, same: false),
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

    /// Un champ inconnu ne compte pas (fournisseur comme système).
    @Test func anUnknownFieldDoesNotMakeAnotherVoice() throws {
        let provider = try Self.decode(
            #"{"providerID":"00000000-0000-0000-0000-00000000D0B1","model":"modele-voix-exemple","identifier":"voix-exemple","language":"fr-CA","gender":"female","extra":{"cle-exemple":"valeur-exemple"},"nuance":"douce"}"#)
        #expect(provider.isSameVoice(as: Self.providerVoice))
        let system = try Self.decode(#"{"identifier":"voix.exemple.a","language":"fr-FR","nuance":"douce"}"#)
        #expect(system.isSameVoice(as: Self.systemVoice))
    }
}
