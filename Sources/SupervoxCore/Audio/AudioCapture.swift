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
}

/// Capture du micro par `AVAudioEngine`, avec annulation d'écho (voice processing) activée par défaut.
///
/// - Seul le premier canal est lu, sans supposer leur nombre : le voice processing en livre 9 sur les haut-parleurs
///   intégrés et 3 sur un casque Bluetooth (mesuré), tous identiques.
/// - Les échantillons sont rendus à la fréquence native du périphérique ; le rééchantillonnage est l'affaire de l'appelant.
/// - Une instance sert à plusieurs `start()`/`stop()` successifs : le montage du moteur n'est fait qu'une fois.
public final class AudioCapture {
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
    // Attaché et connecté avant l'activation du voice processing, même s'il ne joue rien : c'est le montage
    // vérifié pendant le cadrage. Sans nœud de lecture connecté, le démarrage n'a jamais été essayé.
    private let anchorPlayer = AVAudioPlayerNode()
    private let voiceProcessing: Bool
    private let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private var wired = false
    private var running = false
    private var description = "entrée audio non initialisée"

    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    /// Nom du micro (si connu), nombre de canaux et fréquence vus au dernier `start()`.
    public var inputDescription: String { description }

    public func start() throws {
        guard !running else { throw AudioCaptureError.alreadyRunning }
        try Self.ensureMicrophoneAccess()
        try wireIfNeeded()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw AudioCaptureError.noInputDevice }
        let device = AVCaptureDevice.default(for: .audio)?.localizedName
        description = "\(device.map { $0 + ", " } ?? "")\(format.channelCount) canaux, \(Int(format.sampleRate)) Hz, canal 1 lu"

        let store = buffer
        store.withLock {
            $0.samples.removeAll(keepingCapacity: true)
            $0.samples.reserveCapacity(Int(format.sampleRate) * 30)
            $0.sampleRate = format.sampleRate
            $0.accepting = true
            $0.firstBufferAt = nil
            $0.firstSampleHostTime = nil
        }
        // Fil audio temps réel : un verrou et un ajout, rien d'autre.
        let tap: AVAudioNodeTapBlock = { pcm, when in
            guard let channels = pcm.floatChannelData else { return }
            let n = Int(pcm.frameLength)
            guard n > 0 else { return }
            let first = UnsafeBufferPointer(start: channels[0], count: n)
            let rate = pcm.format.sampleRate
            // `withLockUnchecked` : le pointeur ne sort pas de la section critique, il n'a pas à être Sendable.
            store.withLockUnchecked {
                guard $0.accepting else { return }
                $0.samples.append(contentsOf: first)
                $0.sampleRate = rate
                if $0.firstBufferAt == nil {
                    $0.firstBufferAt = DispatchTime.now().uptimeNanoseconds
                    $0.firstSampleHostTime = when.isHostTimeValid ? when.hostTime : nil
                }
            }
        }

        do {
            let frames = AVAudioFrameCount((format.sampleRate * Self.tapBufferSeconds).rounded(.up))
            try installTap(on: input, bufferSize: frames, format: format, block: tap)
            engine.prepare()
            store.withLock { $0.engineStartedAt = DispatchTime.now().uptimeNanoseconds }
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            store.withLock { $0.accepting = false }
            throw error as? AudioCaptureError ?? AudioCaptureError.engineFailed(String(describing: error))
        }
        running = true
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
    public func stop() -> AudioClip {
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

    // MARK: - Montage

    private func wireIfNeeded() throws {
        guard !wired else { return }
        if voiceProcessing {
            engine.attach(anchorPlayer)
            try connectAnchorPlayer()
            do { try engine.inputNode.setVoiceProcessingEnabled(true) }
            catch { throw AudioCaptureError.engineFailed("voice processing : \(error)") }
            // Ducking au minimum : on ne veut pas baisser le volume des autres applications pendant la dictée.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        wired = true
    }

    /// `connect(_:to:format:)` est dépréciée en macOS 27 au profit de `connectNode(_:to:format:)` qui lève une erreur
    /// (AVAudioEngine.h : `NS_SWIFT_NAME(connectNode(_:to:format:))`). Le déploiement minimal étant macOS 26,
    /// le compilateur ne signale pas cette dépréciation : on aiguille à la main.
    private func connectAnchorPlayer() throws {
        if #available(macOS 27, *) {
            do { try engine.connectNode(anchorPlayer, to: engine.mainMixerNode, format: nil) }
            catch { throw AudioCaptureError.engineFailed("connexion du nœud de lecture : \(error)") }
        } else {
            engine.connect(anchorPlayer, to: engine.mainMixerNode, format: nil)
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

    /// Sans autorisation, le moteur démarre quand même et livre du silence : on vérifie donc explicitement.
    /// Statut « non déterminé » : on déclenche la demande système et on attend la réponse (une personne doit répondre).
    private static func ensureMicrophoneAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let answer = OSAllocatedUnfairLock(initialState: false)
            let done = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                answer.withLock { $0 = granted }
                done.signal()
            }
            done.wait()
            if answer.withLock({ $0 }) { return }
            throw AudioCaptureError.microphoneAccessDenied("demande d'accès au micro refusée")
        case .denied:
            throw AudioCaptureError.microphoneAccessDenied("accès refusé : l'autoriser pour ce terminal dans Réglages Système > Confidentialité et sécurité > Micro")
        case .restricted:
            throw AudioCaptureError.microphoneAccessDenied("accès au micro restreint par une politique du système")
        @unknown default:
            throw AudioCaptureError.microphoneAccessDenied("statut d'autorisation inconnu")
        }
    }
}
