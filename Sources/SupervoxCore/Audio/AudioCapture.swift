import AVFoundation
import Foundation
import os

public enum AudioCaptureError: Error, Equatable {
    /// macOS refuse (ou interdit) l'accès au micro à ce processus. Le message dit où l'autoriser.
    case microphoneAccessDenied(String)
    /// Le nœud d'entrée annonce 0 canal ou 0 Hz : pas de micro utilisable. Installer un tap sur un tel format
    /// lèverait une exception Objective-C que Swift ne peut pas rattraper.
    case noInputDevice
    case alreadyRunning
    case engineFailed(String)
    /// La lecture demande un moteur démarré (par `start`) : aucun son ne peut être joué avant, ni après `stop()`.
    case notRunning

    /// La raison, en une phrase qui se lit dans le panneau (sans point final) : le texte d'un message déjà passé par une table
    /// fixe, jamais le texte brut d'une erreur système.
    public var reason: String {
        switch self {
        case .microphoneAccessDenied(let message): return message
        case .noInputDevice: return "aucun micro utilisable n'a été trouvé"
        case .alreadyRunning: return "le micro est déjà utilisé"
        case .engineFailed(let message): return "le moteur audio a échoué (\(message))"
        case .notRunning: return "le moteur audio n'est pas démarré"
        }
    }
}

/// Capture du micro par `AVAudioEngine`, avec annulation d'écho (voice processing) activée par défaut.
///
/// - Seul le premier canal est lu, sans supposer leur nombre : le voice processing en livre 9 sur les haut-parleurs
///   intégrés et 3 sur un casque Bluetooth (mesuré), tous identiques.
/// - Les échantillons sont rendus à la fréquence native du périphérique ; le rééchantillonnage est l'affaire de l'appelant.
/// - Une instance sert à plusieurs `start()`/`stop()` successifs : le montage du moteur n'est fait qu'une fois.
/// - Deux usages : le banc d'essai lit le clip rendu par `stop()` ; la dictée reçoit les tranches au fil de l'eau par
///   `start(onChunk:accumulate:)`, avec `accumulate: false` pour ne rien garder en mémoire.
/// - Le même moteur sait aussi **jouer** du son (`play`, `stopPlayback`) : la lecture passe par le nœud connecté avant
///   l'activation du traitement de la voix, ce qui permet à l'annulation d'écho du système de connaître la voix de
///   l'outil. Rien ne change pour une capture qui ne joue rien.
/// - `start`, `stop`, `play` et `stopPlayback` sont sérialisés par un verrou interne (`lifecycle`) ; le reste de l'état est
///   derrière des verrous (`buffer`, `currentGate`, `inputText`, `playback`) : `@unchecked Sendable`.
public final class AudioCapture: @unchecked Sendable {
    /// Échantillons et fréquence, partagés entre le fil audio temps réel (qui ajoute) et l'appelant (qui lit).
    /// Seul état capturé par le tap : jamais `self`.
    private struct Buffer {
        var samples: [Float] = []
        var sampleRate: Double = 0
        var accepting = false
        /// Horloge monotone (`DispatchTime.now().uptimeNanoseconds`) à l'appel de `engine.start()`, puis à la 1re livraison.
        var engineStartedAt: UInt64 = 0
        var firstBufferAt: UInt64?
        /// Instant de capture (`AVAudioTime.hostTime`, ticks mach) du premier échantillon de la prise, tel que le tap le déclare.
        var firstSampleHostTime: UInt64?
    }

    /// Durée de la fenêtre demandée au tap : le SDK annonce une plage de 100 à 400 ms (AVAudioNode.h), en dessous
    /// de laquelle le système ajuste en silence. On demande donc 100 ms, soit le plus court délai de livraison admis.
    private static let tapBufferSeconds = 0.1

    private let engine = AVAudioEngine()
    // Attaché et connecté avant l'activation du voice processing : c'est le montage vérifié pendant le cadrage. Sans nœud
    // de lecture connecté, le démarrage n'a jamais été essayé. Il joue aussi les clips de `play` : même moteur que le micro.
    private let player = AVAudioPlayerNode()
    /// Les clips en file : générations, fin rendue une fois, position. Son propre verrou ; jamais tenu pendant un appel au lecteur.
    let playback = PlaybackTracker()
    private let voiceProcessing: Bool
    private let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    /// Porte de livraison de la prise en cours (une neuve par prise, voir `DeliveryGate`) ; `nil` hors prise.
    private let currentGate = OSAllocatedUnfairLock<DeliveryGate?>(initialState: nil)
    private let promptsForAccess: Bool
    /// Sérialise `start` et `stop` : protège `wired` et `running`.
    private let lifecycle = NSLock()
    private var wired = false
    private var running = false
    /// `true` quand le lecteur est attaché au moteur (seulement avec le traitement de la voix) : sans cela, planifier un tampon
    /// lèverait une exception Objective-C. Protégé par `lifecycle`, comme `wired`.
    private var playerAttached = false
    private let inputText = OSAllocatedUnfairLock(initialState: "entrée audio non initialisée")

    /// - Parameter promptsForAccess: `false` pour une application qui a déjà son propre parcours d'autorisation :
    ///   un statut « non déterminé » lève alors `microphoneAccessDenied` au lieu d'afficher l'invite système et d'attendre
    ///   la réponse (ce qui bloquerait l'appelant).
    public init(voiceProcessing: Bool = true, promptsForAccess: Bool = true) {
        self.voiceProcessing = voiceProcessing
        self.promptsForAccess = promptsForAccess
    }

    /// La raison d'une panne du moteur audio, telle qu'elle peut être montrée dans le panneau : le code d'erreur du système, et
    /// rien du texte de l'erreur (une erreur système peut y mettre une adresse, un chemin ou un nom de fichier).
    static func reason(for error: any Error) -> String {
        "code d'erreur du système : \((error as NSError).code)"
    }

    /// Nom du micro (si connu), nombre de canaux et fréquence vus au dernier `start()`.
    public var inputDescription: String { inputText.withLock { $0 } }

    /// Démarre sans livraison de tranches : seul `stop()` rend l'enregistrement (usage du banc d'essai).
    public func start() throws {
        try start(onChunk: nil, accumulate: true)
    }

    /// Démarre la capture. Si `onChunk` est fourni, il reçoit chaque fenêtre du tap (premier canal, fréquence native),
    /// dans l'ordre, **sur le fil du tap** : il doit rester bref, ne prendre aucun verrou que l'appelant de `stop()`
    /// peut tenir, et ne jamais appeler `stop()` (précondition). Après le retour de `stop()`, plus aucun appel n'arrive.
    ///
    /// - Parameter accumulate: `true` (défaut) : le tampon interne garde tout, `stop()` rend le clip. `false` : rien
    ///   n'est gardé (mémoire constante), `stop()` rend un clip vide ; exige `onChunk`.
    public func start(onChunk: (@Sendable (AudioChunk) -> Void)? = nil, accumulate: Bool = true) throws {
        precondition(onChunk != nil || accumulate, "accumulate: false sans onChunk n'enregistrerait rien")
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !running else { throw AudioCaptureError.alreadyRunning }
        try ensureMicrophoneAccess()
        try wireIfNeeded()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw AudioCaptureError.noInputDevice }
        let device = AVCaptureDevice.default(for: .audio)?.localizedName
        inputText.withLock {
            $0 = "\(device.map { $0 + ", " } ?? "")\(format.channelCount) canaux, \(Int(format.sampleRate)) Hz, canal 1 lu"
        }

        let tap = makeTap(sampleRate: format.sampleRate, accumulate: accumulate, onChunk: onChunk)
        let store = buffer
        do {
            let frames = AVAudioFrameCount((format.sampleRate * Self.tapBufferSeconds).rounded(.up))
            try installTap(on: input, bufferSize: frames, format: format, block: tap)
            engine.prepare()
            store.withLock { $0.engineStartedAt = DispatchTime.now().uptimeNanoseconds }
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            store.withLock { $0.accepting = false }
            currentGate.withLock { $0 }?.close()
            throw error as? AudioCaptureError ?? AudioCaptureError.engineFailed(Self.reason(for: error))
        }
        running = true
    }

    /// Prépare une prise (remet le tampon à zéro, ouvre une porte de livraison neuve) et rend le bloc du tap. Séparé
    /// de `start` pour être exercé sans micro par des tampons synthétiques.
    ///
    /// Fil du tap : un verrou pour le tampon, une copie `[Float]` et l'appel de `onChunk` sous la porte de livraison ;
    /// aucun autre travail.
    func makeTap(sampleRate: Double, accumulate: Bool,
                 onChunk: (@Sendable (AudioChunk) -> Void)?) -> AVAudioNodeTapBlock {
        let store = buffer
        store.withLock {
            $0.samples.removeAll(keepingCapacity: true)
            if accumulate { $0.samples.reserveCapacity(Int(sampleRate) * 30) }
            $0.sampleRate = sampleRate
            $0.accepting = true
            $0.firstBufferAt = nil
            $0.firstSampleHostTime = nil
        }
        let gate = DeliveryGate()
        // Une prise encore ouverte (cas anormal) est fermée avant d'être remplacée.
        currentGate.withLock { old in
            let previous = old
            old = gate
            return previous
        }?.close()
        return { pcm, when in
            guard let channels = pcm.floatChannelData else { return }
            let n = Int(pcm.frameLength)
            guard n > 0 else { return }
            let first = UnsafeBufferPointer(start: channels[0], count: n)
            let rate = pcm.format.sampleRate
            // `withLockUnchecked` : le pointeur ne sort pas de la section critique, il n'a pas à être Sendable.
            store.withLockUnchecked {
                guard $0.accepting else { return }
                if accumulate { $0.samples.append(contentsOf: first) }
                $0.sampleRate = rate
                if $0.firstBufferAt == nil {
                    $0.firstBufferAt = DispatchTime.now().uptimeNanoseconds
                    $0.firstSampleHostTime = when.isHostTimeValid ? when.hostTime : nil
                }
            }
            if let onChunk {
                let chunk = AudioChunk(samples: Array(first), sampleRate: rate)
                gate.deliver { onChunk(chunk) }
            }
        }
    }

    /// Délai (secondes) entre l'appel de `engine.start()` et la livraison du premier buffer du tap, au dernier
    /// `start()` ; `nil` si rien n'a été livré. Un tap livre par fenêtres : tant que la première n'est pas pleine,
    /// rien n'arrive, et les premiers instants d'une prise ne sont pas dans le clip.
    public var startLatency: Double? {
        buffer.withLock { state in
            state.firstBufferAt.map { Double($0 &- state.engineStartedAt) / 1e9 }
        }
    }

    /// Pour les tests : instant de capture du premier échantillon (ticks mach), à comparer à `mach_absolute_time()`.
    var firstSampleHostTime: UInt64? { buffer.withLock { $0.firstSampleHostTime } }

    /// Arrête la capture et rend ce qui a été **livré** par le tap.
    ///
    /// Contrat sur la fin de prise : le tap livre par fenêtres de `tapBufferSeconds` (100 ms demandées ; le SDK
    /// admet 100 à 400 ms et peut ajuster). `stop()` arrête le moteur sans vider la fenêtre en cours : tout ce qui
    /// a été capté depuis la dernière livraison est perdu, soit jusqu'à une fenêtre, **100 ms demandées et jusqu'à
    /// 400 ms au pire** si le système élargit. Un appelant qui ne peut pas perdre la fin d'une phrase doit laisser
    /// tourner la capture au moins 400 ms après le dernier son voulu avant d'appeler `stop()` (c'est ce que fait
    /// `RecordSession`).
    ///
    /// Si `onChunk` a été fourni : `stop()` attend la fin d'un appel en cours et plus aucun n'arrive après son retour.
    /// Ne pas l'appeler depuis `onChunk` (précondition).
    public func stop() -> AudioClip {
        // Avant de prendre `lifecycle` : un `stop()` venu de `onChunk` doit échouer net, non attendre un autre `stop()`.
        currentGate.withLock { $0 }?.assertNotDelivering()
        lifecycle.lock()
        defer { lifecycle.unlock() }
        // D'abord : une livraison en cours se termine, aucune autre ne commence.
        currentGate.withLock { $0 }?.close()
        // Puis la lecture, avant le moteur : chaque clip en file reçoit `.stopped`. Sans clip en file, le lecteur n'est pas touché.
        stopPlayerLocked()
        if running {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            running = false
        }
        return buffer.withLock {
            $0.accepting = false
            return AudioClip(samples: $0.samples, sampleRate: $0.sampleRate)
        }
    }

    // MARK: - Lecture

    /// Joue un clip dans le moteur de la capture, à la suite de ceux déjà en file. `onEnd` est appelé **une fois**, jamais sur le fil
    /// de l'appelant ni sur le fil principal : `.played` quand le dernier échantillon est sorti du périphérique (`.dataPlayedBack`,
    /// mesuré : 44 à 51 ms après la durée du tampon), `.stopped` si `stopPlayback()` ou `stop()` l'a coupé avant. Il peut arriver
    /// juste après le retour de l'appel qui coupe.
    ///
    /// - Throws: `notRunning` si le moteur ne tourne pas (`start` pas appelé, ou `stop` passé) ; `engineFailed` pour une capture sans
    ///   traitement de la voix (pas de lecteur), un clip vide ou illisible, ou un échec du lecteur. Rien n'est joué, `onEnd` n'est pas appelé.
    public func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws {
        // La conversion se fait hors verrou : elle peut durer, et `stop()` ne doit pas l'attendre.
        let format = try lifecycle.withLock { try playerFormat() }
        guard let buffer = Self.playbackBuffer(clip, format: format) else {
            throw AudioCaptureError.engineFailed("clip audio vide ou illisible")
        }
        try lifecycle.withLock {
            guard try playerFormat() == buffer.format else { throw AudioCaptureError.engineFailed("format de sortie modifié pendant la conversion") }
            // Le lecteur démarre d'abord : s'il échoue, rien n'est planifié ni enregistré, aucun `onEnd` n'est dû.
            try startPlayer()
            let generation = playback.register(
                frames: Int64(buffer.frameLength), sampleRate: buffer.format.sampleRate, nowSample: playerSampleTime(), onEnd: onEnd)
            let tracker = playback
            // Le gestionnaire ne fait que régler le clip dans le suivi : aucun appel au nœud, aucun verrou de `lifecycle`.
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in tracker.settle(generation) }
        }
    }

    /// Coupe tout de suite la lecture et vide la file : chaque clip en file reçoit `.stopped`. Sans effet si rien ne joue. Jamais depuis `onEnd`
    /// (précondition). Ne touche pas à la capture.
    public func stopPlayback() {
        // Avant de prendre `lifecycle` : même ordre que `stop()` depuis `onChunk`.
        playback.assertNotInEndHandler()
        lifecycle.withLock { stopPlayerLocked() }
    }

    /// Secondes déjà jouées du clip en cours (le plus ancien de la file) ; `nil` sans lecture.
    public var playbackPosition: Double? {
        playback.position(currentSample: { playerSampleTime() })
    }

    /// Appelée sous `lifecycle`. Le suivi n'appelle le lecteur que s'il reste des clips ; le lecteur rappelle ses gestionnaires
    /// de façon synchrone depuis `stop()` (mesuré) : ils ne prennent que le verrou du suivi, que `stopAll` ne tient pas ici.
    private func stopPlayerLocked() {
        playback.stopAll { player.stop() }
    }

    /// Le format de sortie du lecteur, lu à chaque lecture (il n'est jamais supposé) ; lève si rien ne peut être joué.
    private func playerFormat() throws -> AVAudioFormat {
        guard running, engine.isRunning else { throw AudioCaptureError.notRunning }
        guard playerAttached else { throw AudioCaptureError.engineFailed("lecture impossible sans traitement de la voix") }
        return player.outputFormat(forBus: 0)
    }

    /// Temps du lecteur en trames de sortie, `nil` tant qu'il ne rend pas.
    private func playerSampleTime() -> Int64? {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else { return nil }
        return playerTime.sampleTime
    }

    /// `play()` est dépréciée en macOS 27 au profit de `playAudio()`, qui lève une erreur (AVAudioPlayerNode.h). Mesuré sur un
    /// moteur arrêté : `playAudio()` lève (code −10863), `play()` se tait. Le moteur est donc vérifié ici, pour les deux chemins.
    private func startPlayer() throws {
        guard engine.isRunning else { throw AudioCaptureError.notRunning }
        if #available(macOS 27, *) {
            do { try player.playAudio() }
            catch { throw AudioCaptureError.engineFailed("lecture : \(Self.reason(for: error))") }
        } else {
            player.play()
        }
    }

    /// Un clip mono converti au format du lecteur : fréquence convertie par `AVAudioConverter` (par `Resampler`), le canal recopié sur
    /// chaque canal du format. `nil` pour un clip vide, ou un format où l'on ne peut pas écrire de flottants non entrelacés. NaN et
    /// valeurs infinies deviennent 0, avant le filtre du convertisseur (qui les répandrait sur les voisins).
    static func playbackBuffer(_ clip: AudioClip, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !clip.samples.isEmpty, clip.sampleRate > 0, format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { return nil }
        let clean = AudioClip(samples: clip.samples.map { $0.isFinite ? $0 : 0 }, sampleRate: clip.sampleRate)
        let converted = Resampler.resample(clean, to: format.sampleRate).samples
        guard !converted.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(converted.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(converted.count)
        converted.withUnsafeBufferPointer { source in
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(from: source.baseAddress!, count: source.count)
            }
        }
        return buffer
    }

    // MARK: - Montage

    private func wireIfNeeded() throws {
        guard !wired else { return }
        if voiceProcessing {
            engine.attach(player)
            try connectPlayer()
            playerAttached = true
            do { try engine.inputNode.setVoiceProcessingEnabled(true) }
            catch { throw AudioCaptureError.engineFailed("traitement de la voix : \(Self.reason(for: error))") }
            // Ducking au minimum : on ne veut pas baisser le volume des autres applications pendant la dictée.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        wired = true
    }

    /// `connect(_:to:format:)` est dépréciée en macOS 27 au profit de `connectNode(_:to:format:)` qui lève une erreur
    /// (AVAudioEngine.h : `NS_SWIFT_NAME(connectNode(_:to:format:))`). Le déploiement minimal étant macOS 26,
    /// le compilateur ne signale pas cette dépréciation : on aiguille à la main.
    private func connectPlayer() throws {
        if #available(macOS 27, *) {
            do { try engine.connectNode(player, to: engine.mainMixerNode, format: nil) }
            catch { throw AudioCaptureError.engineFailed("connexion du nœud de lecture : \(Self.reason(for: error))") }
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: nil)
        }
    }

    private func installTap(on node: AVAudioInputNode, bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                            block: @escaping AVAudioNodeTapBlock) throws {
        if #available(macOS 27, *) {
            // La variante qui lève une erreur est importée sous son nom brut (`__installTap`, déclarée
            // NS_REFINED_FOR_SWIFT, sans surcharge Swift dans le SDK 27.2) avec un paramètre `error: ()`.
            try node.__installTap(onBus: 0, bufferSize: bufferSize, format: format, error: (), block: block)
        } else {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        }
    }

    // MARK: - Autorisation micro

    /// Ce qu'il faut faire d'un statut d'autorisation. Séparé de l'appel système pour être testé sans toucher aux
    /// vraies permissions.
    enum AccessDecision: Equatable {
        case granted
        /// Statut « non déterminé » et invite permise : il faut demander à la personne.
        case askUser
        case refused(AudioCaptureError)
    }

    private static let settingsPath = "Réglages Système > Confidentialité et sécurité > Micro"

    static func accessDecision(for status: AVAuthorizationStatus, promptsForAccess: Bool) -> AccessDecision {
        switch status {
        case .authorized:
            return .granted
        case .notDetermined:
            if promptsForAccess { return .askUser }
            return .refused(.microphoneAccessDenied("accès au micro pas encore accordé : l'autoriser dans \(settingsPath)"))
        case .denied:
            return .refused(.microphoneAccessDenied("accès refusé : l'autoriser dans \(settingsPath)"))
        case .restricted:
            return .refused(.microphoneAccessDenied("accès au micro restreint par une politique du système"))
        @unknown default:
            return .refused(.microphoneAccessDenied("statut d'autorisation inconnu"))
        }
    }

    /// Sans autorisation, le moteur démarre quand même et livre du silence : on vérifie donc explicitement.
    /// Statut « non déterminé » : avec `promptsForAccess`, on déclenche la demande système et on attend la réponse
    /// (une personne doit répondre) ; sans, on refuse tout de suite.
    private func ensureMicrophoneAccess() throws {
        switch Self.accessDecision(for: AVCaptureDevice.authorizationStatus(for: .audio), promptsForAccess: promptsForAccess) {
        case .granted:
            return
        case .refused(let error):
            throw error
        case .askUser:
            let answer = OSAllocatedUnfairLock(initialState: false)
            let done = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                answer.withLock { $0 = granted }
                done.signal()
            }
            done.wait()
            if answer.withLock({ $0 }) { return }
            throw AudioCaptureError.microphoneAccessDenied("demande d'accès au micro refusée")
        }
    }
}
