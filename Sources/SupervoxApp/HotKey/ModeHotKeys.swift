/// Les raccourcis propres à chaque mode. Un registraire par mode (un emplacement chacun, voir `HotKeyRegistrar`), fabriqué à la
/// première combinaison du mode et gardé tant que le mode en a une ; un mode qui disparaît ou perd sa combinaison rend la sienne
/// au système et libère son registraire.
///
/// Chaque raccourci est tenu par un `HotKeyCenter` : la validation, le refus du système (l'ancienne combinaison du mode est
/// réenregistrée) et la suspension le temps d'une capture sont les mêmes que pour le raccourci global.
@MainActor
public final class ModeHotKeys {
    private let makeRegistrar: @MainActor () -> any HotKeyRegistrar
    private let layout: any KeyboardLayout
    private var centers: [String: HotKeyCenter] = [:]
    /// Lus à chaque appui : un `apply` plus récent remplace les rappels sans réenregistrer quoi que ce soit.
    private var onPress: (@MainActor (String) -> Void)?
    private var onRelease: (@MainActor (String) -> Void)?

    /// `makeRegistrar` fabrique le registraire d'un mode (en production, un `CarbonHotKeyRegistrar`).
    public init(makeRegistrar: @escaping @MainActor () -> any HotKeyRegistrar, layout: any KeyboardLayout) {
        self.makeRegistrar = makeRegistrar
        self.layout = layout
    }

    /// Les combinaisons actives par mode ; pendant une suspension, celles qui seront prises à la reprise.
    public var active: [String: HotKey] {
        var result = centers.compactMapValues(\.active)
        for (id, hotKey) in pending { result[id] = hotKey }
        return result
    }

    /// Vrai entre `suspend` et `resume`.
    public private(set) var isSuspended = false
    /// Pendant une suspension : les combinaisons que `apply` a demandées et que `resume` prendra.
    private var pending: [String: HotKey] = [:]

    /// Met les raccourcis des modes d'accord avec `bindings` (identifiant du mode vers combinaison). Une combinaison déjà active
    /// n'est pas touchée (ni retirée, ni réenregistrée) ; un mode absent de `bindings` perd la sienne. Les modes sont pris dans
    /// l'ordre de leurs identifiants. Les combinaisons qui changent sont d'abord rendues au système, puis prises : deux modes
    /// qui échangent leurs combinaisons y arrivent. Pendant une suspension (capture), rien n'est enregistré : les nouvelles
    /// combinaisons sont prises à `resume`. Rend, par mode, ce que le système ou la validation a refusé ; un refus n'empêche pas
    /// les autres modes.
    public func apply(
        _ bindings: [String: HotKey], onPress: @escaping @MainActor (String) -> Void,
        onRelease: @escaping @MainActor (String) -> Void
    ) -> [String: HotKeyError] {
        self.onPress = onPress
        self.onRelease = onRelease
        for id in centers.keys.sorted() where bindings[id] == nil { remove(id) }
        for id in pending.keys.sorted() where bindings[id] == nil { pending[id] = nil }
        let ids = bindings.keys.sorted()
        guard !isSuspended else {
            for id in ids { pending[id] = centers[id]?.active == bindings[id] ? nil : bindings[id] }
            return [:]
        }
        for id in ids {
            if let center = centers[id], let current = center.active, current != bindings[id] { center.suspend() }
        }
        var refused: [String: HotKeyError] = [:]
        for id in ids {
            guard let hotKey = bindings[id], centers[id]?.active != hotKey || centers[id]?.isSuspended == true else { continue }
            if case .failure(let error) = register(hotKey, for: id) { refused[id] = error }
        }
        return refused
    }

    /// Donne ce raccourci au mode, ou le lui retire avec `nil`. En cas de refus, l'ancien raccourci du mode reste actif. Pris
    /// tout de suite, même pendant une suspension : c'est ce que fait une capture.
    public func set(_ hotKey: HotKey?, for modeID: String) -> Result<Void, HotKeyError> {
        guard let hotKey else {
            remove(modeID)
            return .success(())
        }
        pending[modeID] = nil
        return register(hotKey, for: modeID)
    }

    /// Rend toutes les combinaisons au système, le temps d'une capture, sans les oublier.
    public func suspend() {
        isSuspended = true
        for center in centers.values { center.suspend() }
    }

    /// Réenregistre ce que `suspend` a rendu et prend les combinaisons que `apply` a demandées entre-temps. Rend les modes que le
    /// système refuse maintenant, dans l'ordre de leurs identifiants : un mode dont la combinaison a changé retrouve l'ancienne,
    /// les autres n'ont plus de raccourci actif.
    public func resume() -> [String] {
        isSuspended = false
        var failed: Set<String> = []
        let waiting = pending
        pending = [:]
        for (id, hotKey) in waiting.sorted(by: { $0.key < $1.key }) {
            if case .failure = register(hotKey, for: id) { failed.insert(id) }
        }
        for (id, center) in centers.sorted(by: { $0.key < $1.key }) where !center.resume() { failed.insert(id) }
        return failed.sorted()
    }

    private func register(_ hotKey: HotKey, for id: String) -> Result<Void, HotKeyError> {
        let isNew = centers[id] == nil
        let center = centers[id] ?? HotKeyCenter(registrar: makeRegistrar(), layout: layout)
        let result = center.apply(
            hotKey, onPress: { [weak self] in self?.onPress?(id) }, onRelease: { [weak self] in self?.onRelease?(id) })
        // Une première combinaison refusée ne laisse rien derrière elle ; sinon le registraire du mode reste.
        if isNew, case .failure = result { return result }
        centers[id] = center
        return result
    }

    private func remove(_ id: String) {
        pending[id] = nil
        centers.removeValue(forKey: id)?.clear()
    }
}
