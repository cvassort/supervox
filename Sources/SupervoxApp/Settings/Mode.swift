import Foundation

/// Un fournisseur et l'un de ses modèles, tels que les réglages les retiennent. Le fournisseur se retrouve par son
/// identifiant dans `AppSettings.providers`.
public struct ModelChoice: Codable, Equatable, Sendable {
    public var providerID: UUID
    public var model: String

    public init(providerID: UUID, model: String) {
        self.providerID = providerID
        self.model = model
    }
}

/// Un mode de dictée, tel qu'il est enregistré dans `settings.json` sous `AppSettings.modes`. Les quatre modes de base
/// (`Mode.base`) et les modes personnels sont de même nature : seuls leurs identifiants et ce que l'on peut en faire diffèrent.
///
/// Chaque champ facultatif a un `nil` qui veut dire « la valeur par défaut » : consigne d'origine, modèle fort, moteur de
/// l'onglet Transcription, pas de raccourci, choix de relecture du mode. Un champ que cette version ne connaît pas est gardé
/// et réécrit tel quel (voir `UnknownFields`).
public struct Mode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// `nil` : la consigne d'origine d'un mode de base (`ModeDefaults`). `""` : un mode personnel sans consigne.
    public var instruction: String?
    /// `nil` : le modèle fort des réglages.
    public var model: ModelChoice?
    /// `nil` : le moteur de l'onglet Transcription.
    public var engine: TranscriptionEngine?
    public var hotKey: HotKey?
    /// `nil` : le défaut du mode (`AppSettings.reviewDefault`).
    public var reviewBeforePaste: Bool?
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(
        id: String, name: String, instruction: String? = nil, model: ModelChoice? = nil,
        engine: TranscriptionEngine? = nil, hotKey: HotKey? = nil, reviewBeforePaste: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.model = model
        self.engine = engine
        self.hotKey = hotKey
        self.reviewBeforePaste = reviewBeforePaste
    }

    // MARK: - Ce que le mode est

    /// Les quatre modes de base, dans l'ordre des pastilles du panneau, avec leur consigne d'origine (`instruction` à `nil`).
    public static let base: [Mode] = ModeChip.fixed.map { Mode(id: $0.id, name: $0.title) }

    /// Le mode est l'un des quatre de base.
    public var isBase: Bool { ModeChip.fixed.contains { $0.id == id } }

    /// Dictée brute et Entretien ne se suppriment pas : l'application en dépend (le texte tel quel, l'entretien).
    public var canDelete: Bool { !Self.isFixed(id) }

    /// Leur consigne n'est pas à l'utilisateur : le texte n'y passe pas par le modèle de langage.
    public var instructionIsEditable: Bool { !Self.isFixed(id) }

    /// La consigne qui s'applique : celle du mode, ou son origine pour un mode de base qui n'en a pas ; vide pour Dictée brute
    /// et Entretien, quoi que le fichier ait porté.
    public var effectiveInstruction: String {
        guard instructionIsEditable else { return "" }
        return instruction ?? ModeDefaults.instruction(for: id) ?? ""
    }

    /// Le texte de ce mode passe par le modèle de langage : une consigne qui dit quelque chose, hors Dictée brute et Entretien.
    public var usesModel: Bool {
        instructionIsEditable && !effectiveInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// La pastille du panneau.
    public var chip: ModeChip { ModeChip(id: id, title: name) }

    /// Un identifiant neuf pour un mode personnel : `perso-` et un UUID en minuscules.
    public static func newID() -> String { "perso-" + UUID().uuidString.lowercased() }

    private static func isFixed(_ id: String) -> Bool { id == ModeChip.rawID || id == ModeChip.interviewID }

    // MARK: - Lecture et écriture

    /// Les modes d'un fichier : un identifiant déjà vu est écarté (le premier reste), et Dictée brute et Entretien, que
    /// l'application ne sait pas se passer, retrouvent leur place de `Mode.base` s'ils manquent. Dictée nettoyée et Prompt, eux,
    /// peuvent avoir été supprimés.
    static func normalized(_ modes: [Mode]) -> [Mode] {
        var seen = Set<String>()
        var result = modes.filter { seen.insert($0.id).inserted }
        for (index, base) in Mode.base.enumerated() where !base.canDelete && !seen.contains(base.id) {
            result.insert(base, at: min(index, result.count))
        }
        return result
    }

    private enum CodingKeys: String, CaseIterable {
        case id, name, instruction, model, engine, hotKey, reviewBeforePaste
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// `id` et `name` sont obligatoires (sans eux, le mode n'a pas de sens : le fichier est illisible). Une consigne absente se
    /// lit `""` pour un mode personnel, et reste `nil` (l'origine) pour un mode de base.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        id = try container.decode(String.self, forKey: key(.id))
        name = try container.decode(String.self, forKey: key(.name))
        model = try container.decodeIfPresent(ModelChoice.self, forKey: key(.model))
        engine = try container.decodeIfPresent(TranscriptionEngine.self, forKey: key(.engine))
        hotKey = try container.decodeIfPresent(HotKey.self, forKey: key(.hotKey))
        reviewBeforePaste = try container.decodeIfPresent(Bool.self, forKey: key(.reviewBeforePaste))
        let isBase = ModeChip.fixed.contains { $0.id == id }
        instruction = try container.decodeIfPresent(String.self, forKey: key(.instruction)) ?? (isBase ? nil : "")
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        try container.encode(id, forKey: key(.id))
        try container.encode(name, forKey: key(.name))
        try container.encodeIfPresent(instruction, forKey: key(.instruction))
        try container.encodeIfPresent(model, forKey: key(.model))
        try container.encodeIfPresent(engine, forKey: key(.engine))
        try container.encodeIfPresent(hotKey, forKey: key(.hotKey))
        try container.encodeIfPresent(reviewBeforePaste, forKey: key(.reviewBeforePaste))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}
