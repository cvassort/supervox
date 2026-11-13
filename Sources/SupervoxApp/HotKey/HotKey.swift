/// Raccourci clavier global : une touche (code virtuel) et ses modificateurs.
public struct HotKey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Contrôle + option + espace.
    public static let standard = HotKey(keyCode: 49, modifiers: [.control, .option])
}

/// Modificateurs d'un raccourci. Les valeurs sont celles de Carbon
/// (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`) et sont écrites telles quelles
/// dans le fichier de réglages : ne pas les renuméroter.
public struct Modifiers: OptionSet, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = Modifiers(rawValue: 1 << 8)
    public static let shift = Modifiers(rawValue: 1 << 9)
    public static let option = Modifiers(rawValue: 1 << 11)
    public static let control = Modifiers(rawValue: 1 << 12)
}
