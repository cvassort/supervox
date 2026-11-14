import AppKit

/// Le presse-papiers général du système (`NSPasteboard.general`).
///
/// Le texte dicté est une donnée privée : il n'est jamais écrit dans un journal ni un message d'erreur.
@MainActor public final class SystemPasteboard: Pasteboard {
    /// Type du texte (`public.utf8-plain-text`).
    static let textType = NSPasteboard.PasteboardType.string.rawValue
    /// Les marques que les gestionnaires de presse-papiers respectent (convention publiée sur nspasteboard.org) :
    /// la copie est transitoire, et son contenu est confidentiel. Elles n'ont pas besoin de données.
    static let transientTypes = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]

    private let board: NSPasteboard

    public init() { board = .general }

    /// Sur un autre presse-papiers (un presse-papiers nommé, pour les tests d'intégration).
    init(board: NSPasteboard) { self.board = board }

    public var changeCount: Int { board.changeCount }

    public func read() -> PasteboardContents {
        let items = (board.pasteboardItems ?? []).map { item in
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type.rawValue] = data }
            }
            return entry
        }
        return PasteboardContents(items: items)
    }

    public func write(_ contents: PasteboardContents) {
        board.clearContents()
        let objects = contents.items.filter { !$0.isEmpty }.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !objects.isEmpty { board.writeObjects(objects) }
    }

    public func writeText(_ text: String, transient: Bool) {
        write(Self.contents(forText: text, transient: transient))
    }

    /// Ce que `writeText` écrit : un élément, le texte en UTF-8, et si `transient`, les marques transitoire et
    /// confidentielle (avec des données vides).
    static func contents(forText text: String, transient: Bool) -> PasteboardContents {
        var entry: [String: Data] = [textType: Data(text.utf8)]
        if transient { for type in transientTypes { entry[type] = Data() } }
        return PasteboardContents(items: [entry])
    }
}
