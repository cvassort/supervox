import Foundation
import os

// L'écoute de l'entretien : tranches du micro, détecteur, aperçu, transcription d'un tour, chien de garde du micro.
extension ConversationChain {
    // MARK: Écoute

    enum Listening {
        case turn(AudioClip)
        case interrupted
        case failed(ConversationFailure)
    }

    /// Écoute jusqu'à ce que le détecteur ferme un passage, ou que la conversation soit interrompue.
    func listen() async -> Listening {
        let (chunks, chunkSink) = AsyncStream<AudioChunk>.makeStream()
        intake.open(chunkSink)
        startPreview()
        emit(.state(.listening))
        var result: Listening?
        for await chunk in chunks {
            if let step = await ingest(chunk) {
                result = step
                break
            }
        }
        intake.closeEpoch()
        // L'aperçu est annulé et attendu avant tout : le moteur de transcription n'a jamais deux appels en même temps.
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil
        return result ?? .interrupted
    }

    func ingest(_ chunk: AudioChunk) async -> Listening? {
        let step = await process(chunk)
        emit(.level(AudioLevel.display(of: chunk.samples)))
        return step
    }

    func process(_ chunk: AudioChunk) async -> Listening? {
        if resampler == nil || inputRate != chunk.sampleRate {
            guard let made = makeResampler(chunk.sampleRate, transcriberSampleRate) else {
                return .failed(.microphone(ConversationFailure.Code.unusableSampleRate))
            }
            resampler = made
            inputRate = chunk.sampleRate
        }
        guard let resampler else { return nil }
        let converted = resampler.push(chunk.samples)
        if resampler.hasFailed { return .failed(.microphone(ConversationFailure.Code.conversionFailed)) }
        for block in timeline.append(converted) {
            do {
                if let event = try await detector.process(block) { timeline.apply(event) }
            } catch {
                return Task.isCancelled ? .interrupted : .failed(.engine(ConversationFailure.Code.detectorFailed))
            }
            // Le silence qui termine le tour est celui du détecteur : le premier passage fermé est le tour.
            if let segment = timeline.closedSegments.first { return .turn(paddedClip(of: segment)) }
        }
        return nil
    }

    /// Le passage fermé, élargi de `padding` secondes de chaque côté et borné à l'audio reçu.
    func paddedClip(of segment: Range<Int>) -> AudioClip {
        let seconds = config.padding.isFinite ? min(max(config.padding, 0), 60) : 0   // 60 s : borne de sûreté, choix non mesuré
        let pad = Int((seconds * transcriberSampleRate).rounded())
        return timeline.clip(of: (segment.lowerBound - pad)..<(segment.upperBound + pad))
    }

    // MARK: Aperçu

    /// Une tâche qui, toutes les `previewInterval` secondes (attente injectée), transcrit le passage ouvert. Une passe à la fois :
    /// la suivante n'attend qu'après la fin de la précédente.
    func startPreview() {
        let interval = config.previewInterval
        let sleep = sleep
        previewTask = Task {
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self.previewPass()
            }
        }
    }

    func previewPass() async {
        // `.infinity` : le passage ouvert en entier, pour que le texte provisoire soit celui du passage et non de sa fin.
        guard let start = timeline.openSegmentStart, let clip = timeline.openClip(maxSeconds: .infinity) else { return }
        let engine = transcriber
        let language = config.language
        let vocabulary = config.vocabulary
        // Bornée par `Deadline` : un moteur sourd à l'annulation ne retient pas l'écoute (qui attend cette passe) ni les passes suivantes.
        let text = try? await Deadline.run(seconds: config.transcriptionTimeout, sleep: transcriptionSleep) {
            try await engine.transcribe(clip, language: language, vocabulary: vocabulary)
        }
        // Le résultat d'une passe qui revient après la fermeture du passage, ou après l'écoute, ne se montre pas.
        guard let text, !Task.isCancelled, timeline.openSegmentStart == start else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { emit(.partialTranscript(trimmed)) }
    }

    // MARK: Transcription

    enum Transcription {
        case text(String)
        case failed(String)
        case cancelled
    }

    /// La transcription part dans une tâche à part : `conclude()` et une panne du micro n'annulent pas ce qui vient d'être dit. Seul
    /// `cancel()` l'annule ; et `Deadline` la borne (`transcriptionTimeout`) sans attendre un moteur qui n'écoute pas l'annulation :
    /// `cancel()` rend donc la main même avec un moteur sourd. Rien ne part après une annulation.
    func transcribe(_ clip: AudioClip) async -> Transcription {
        if request == .cancel { return .cancelled }
        let engine = transcriber
        let language = config.language
        let vocabulary = config.vocabulary
        let timeout = config.transcriptionTimeout
        let sleep = transcriptionSleep
        // Aucune suspension entre le contrôle ci-dessus et la case `transcribeTask` : `cancel()` ne peut pas passer entre les deux.
        let task = Task {
            try await Deadline.run(seconds: timeout, sleep: sleep) {
                try await engine.transcribe(clip, language: language, vocabulary: vocabulary)
            }
        }
        transcribeTask = task
        let result = await task.result
        transcribeTask = nil
        switch result {
        case .success(let text):
            return .text(text)
        case .failure(let error):
            if error is DeadlineExceeded { return .failed(ConversationFailure.Code.transcriptionTimedOut) }
            return error is CancellationError || task.isCancelled ? .cancelled : .failed(Self.transcriptionCode(of: error))
        }
    }

    // MARK: Chien de garde du micro

    func startWatchdog() {
        let watchdog = watchdog
        watchdogTask = Task {
            while !Task.isCancelled {
                do { try await watchdog.sleep(watchdog.pollInterval) } catch { return }
                guard self.microphoneIsAlive() else { return }
            }
        }
    }

    /// Faux quand la tâche doit s'arrêter : l'entretien ne parle plus au micro, ou le micro s'est tu (l'entretien échoue alors).
    func microphoneIsAlive() -> Bool {
        guard stage == .talking, audioOpen else { return false }
        // Avant toute tranche, la tolérance est celle de l'ouverture du micro ; ensuite, celle de l'écart entre deux tranches.
        let limit = intake.hasSeenAChunk ? watchdog.timeout : watchdog.firstChunkTimeout
        guard now() - intake.lastArrival >= limit else { return true }
        fail(.microphone(ConversationFailure.Code.silent))
        return false
    }
}
