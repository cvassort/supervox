import Foundation
import Synchronization
import SupervoxApp
import SupervoxCore
import Testing

@testable import Supervox

/// I5 : une VRAIE `DictationSession`, fabriquée par le vrai `LiveDictationEngines.environment`, derrière le vrai
/// `DictationController` et le vrai `TextInserter`. Tout ce qui touche le monde est double : micro scripté, détecteur et
/// moteurs doubles, presse-papiers et touches doubles, panneau double. Aucun micro, aucun modèle, aucun ⌘V, aucun
/// presse-papiers du système, aucun réseau, aucun temps réel (le chien de garde du micro est éteint : un micro scripté livre
/// tout à l'ouverture puis se tait).

/// Presse-papiers en mémoire : garde les textes écrits.
@MainActor final class MemoryPasteboard: PasteboardAccess {
    private(set) var changeCount = 0
    private var contents = PasteboardContents(items: [])
    private(set) var texts: [String] = []

    func read() -> PasteboardContents { contents }

    @discardableResult func write(_ contents: PasteboardContents) -> Bool {
        self.contents = contents
        changeCount += 1
        return true
    }

    @discardableResult func writeText(_ text: String, transient: Bool) -> Bool {
        texts.append(text)
        contents = PasteboardContents(items: [["public.utf8-plain-text": Data(text.utf8)]])
        changeCount += 1
        return true
    }
}

/// Poseur de touches double : compte les ⌘V qu'il aurait postés, aucune touche modificatrice tenue.
@MainActor final class RecordingKeys: KeyPoster {
    private(set) var pastes = 0
    func modifiersHeld() -> Bool { false }
    func postPaste(keyCode: UInt16) -> Bool {
        pastes += 1
        return true
    }
}

struct ANSILetterV: KeyboardLayout {
    func character(forKeyCode keyCode: UInt32) -> String? { keyCode == 0x09 ? "v" : nil }
}

/// Un micro scripté qui compte ses ouvertures et ses arrêts.
final class CountingFeed: MicrophoneFeed, @unchecked Sendable {
    private let inner: ScriptedMicrophoneFeed
    private let counts = Mutex((starts: 0, stops: 0))

    init(chunks: [AudioChunk]) { inner = ScriptedMicrophoneFeed(chunks: chunks) }

    var starts: Int { counts.withLock { $0.starts } }
    var stops: Int { counts.withLock { $0.stops } }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        counts.withLock { $0.starts += 1 }
        try inner.start(onChunk: onChunk)
    }

    func stop() {
        counts.withLock { $0.stops += 1 }
        inner.stop()
    }
}

@MainActor private final class Panel: PanelOpening {
    private(set) var isOpen = false
    var onClosed: (@MainActor () -> Void)?
    func open() { isOpen = true }
    func setKeyboard(_ keyboard: PanelKeyboard) {}
    func close() {
        guard isOpen else { return }
        isOpen = false
        onClosed?()
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DictationEndToEndTests {
    private let doubles = DoubleEngines()
    private let feed: CountingFeed
    private let panel = Panel()
    private let board = MemoryPasteboard()
    private let keys = RecordingKeys()
    private let controller: DictationController

    /// Trois blocs de parole (le premier ouvre un passage, au détecteur double).
    private static let speech = [
        AudioChunk(samples: [Float](repeating: 0.05, count: 3000), sampleRate: 16000)
    ]

    init(behavior: HotKeyBehavior = .toggle, chunks: [AudioChunk] = DictationEndToEndTests.speech) {
        let doubles = doubles
        let feed = CountingFeed(chunks: chunks)
        self.feed = feed
        let engines = LiveDictationEngines(
            modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"),
            base: LiveDictationTests.StubCatalog(LiveDictationTests.StubCatalog.allReady),
            makeFeed: { feed }, factory: doubles.factory, watchdog: nil)
        let inserter = TextInserter(
            pasteboard: board, keys: keys, layout: ANSILetterV(), isTrusted: { true }, wait: { _ in })
        let panel = panel
        controller = DictationController(
            environment: engines.environment, inserter: inserter,
            settings: { TranscriptionSettings(engine: .whisperKit, whisperModel: "small", language: "fr", vocabulary: []) },
            behavior: { behavior }, modeID: { "dictee-brute" }, microphoneAllowed: { true }, panel: panel,
            hotKeyModifiers: { [.control, .option] },
            // Une attente qui ne rend la main qu'à l'annulation : aucun sondage réel du clavier.
            hold: HoldWatch(anyHeld: { _ in true }, wait: { _ in try? await Task.sleep(for: .seconds(3600)) }),
            beforeMicrophone: {})
        panel.onClosed = { [controller] in controller.panelClosedByUser() }
    }

    private func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for round in 0..<20000 {
            if condition() { return true }
            if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
        }
        return condition()
    }

    private func settle() async {
        for round in 0..<300 {
            if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
        }
    }

    // MARK: - Bascule

    /// Appui, parole, appui : le texte du moteur final est inséré une seule fois, le micro est ouvert puis arrêté, le panneau
    /// se ferme.
    @Test func toggleDictationInsertsTheFinalTextExactlyOnce() async {
        controller.hotKeyPressed()
        #expect(controller.view.stage == .preparing)
        #expect(await until { controller.view.stage == .recording })
        #expect(feed.starts == 1)
        #expect(doubles.detector.prepares == 1)
        #expect(doubles.whisper("small").prepares == 1)

        controller.hotKeyPressed()
        #expect(await until { keys.pastes == 1 && !panel.isOpen })
        await settle()

        #expect(board.texts == ["texte whisper"])
        #expect(keys.pastes == 1)
        #expect(doubles.whisper("small").transcriptions == 1)
        #expect(feed.stops >= 1)
        #expect(controller.view == DictationViewState(lastTranscript: "texte whisper"))
        #expect(controller.lastTranscript == "texte whisper")
        #expect(!controller.isBusy)
    }

    // MARK: - Maintien relâché pendant la préparation

    /// Le relâchement arrive avant l'ouverture du micro : « Rien à transcrire », le micro n'est jamais ouvert, rien n'est inséré.
    @Test func holdReleasedDuringPreparationSaysNothingToTranscribeAndNeverOpensTheMicrophone() async {
        let hold = Self(behavior: .hold)
        let gate = Gate()
        defer { gate.open() }
        hold.doubles.detector.holdPrepare(with: gate)

        hold.controller.hotKeyPressed()
        #expect(await hold.until { hold.doubles.detector.prepares == 1 })
        #expect(hold.controller.view.stage == .preparing)

        hold.controller.hotKeyReleased()
        await hold.settle()
        // Toujours en préparation : la fin est retenue, le micro n'est pas ouvert.
        #expect(hold.feed.starts == 0)
        gate.open()

        #expect(await hold.until { hold.controller.view.stage == .failed(.noSpeech) })
        #expect(DictationText.status(for: hold.controller.view.stage) == "Rien à transcrire")
        #expect(hold.feed.starts == 0)
        #expect(hold.doubles.whisper("small").transcriptions == 0)
        #expect(hold.board.texts.isEmpty)
        #expect(hold.keys.pastes == 0)
        #expect(hold.panel.isOpen)
    }

    // MARK: - Échap pendant la transcription

    /// Le moteur final répond après l'annulation : le texte n'est ni inséré, ni copié, ni montré.
    @Test func escapeWhileFinalizingInsertsNothingEvenWhenTheEngineAnswersLater() async {
        let gate = Gate()
        defer { gate.open() }
        doubles.whisper("small").hold(with: gate)

        controller.hotKeyPressed()
        #expect(await until { controller.view.stage == .recording })
        controller.hotKeyPressed()
        #expect(await until { doubles.whisper("small").transcriptions == 1 })
        #expect(await until { controller.view.stage == .finalizing })

        controller.escapePressed()
        #expect(!panel.isOpen)
        #expect(controller.view == DictationViewState())

        gate.open()
        #expect(await until { doubles.whisper("small").completions == 1 })
        await settle()

        #expect(board.texts.isEmpty)
        #expect(keys.pastes == 0)
        #expect(controller.view == DictationViewState())
        #expect(controller.lastTranscript == nil)
        #expect(!controller.isBusy)
        #expect(feed.stops >= 1)
    }
}
