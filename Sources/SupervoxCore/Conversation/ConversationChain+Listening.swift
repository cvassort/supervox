import Foundation
import os

// L'écoute de l'entretien : tranches du micro, détecteur, passages, porte d'interruption, aperçu, transcription des tours, chien de
// garde du micro.
extension ConversationChain {
    // MARK: Passages

    /// D'où vient le passage ouvert, ce qui décide de ce qu'il devient à sa fermeture.
    enum PassageOrigin: Equatable {
        /// Ouvert pendant que l'outil écoute : c'est un tour.
        case listening
        /// Ouvert pendant que l'outil transcrit, réfléchit ou parle, sous le seuil de la porte : peut-être l'écho de sa voix. Fermé
        /// ainsi, il est jeté.
        case busy
        /// Ouvert pendant que l'outil était occupé, et la porte a dit oui : c'est un tour, transcrit depuis son début.
        case interrupting
        /// Ouvert pendant que l'outil était occupé, et encore ouvert quand il a fini : il ne compte qu'à partir de cet échantillon,
        /// et seulement si la porte d'interruption passe sur ce qui suit (mêmes seuils, même fenêtre). L'écho qui traîne après la
        /// parole est sous le seuil par hypothèse : il ne fait pas un tour fantôme (revue de la tâche 6, I-3).
        case rebased(at: Int)
    }

    /// L'outil a quelque chose en cours qui vient d'un tour de la personne : transcription, tour à transcrire, réplique attendue ou en
    /// cours.
    var isBusy: Bool { transcription != nil || !clipsToTranscribe.isEmpty || awaitingReply || replyActive }

    var interruptingPassageIsOpen: Bool { timeline.openSegmentStart != nil && passageOrigin == .interrupting }

    /// Le remplissage, en échantillons (0,3 s par défaut, choix non mesuré ; borné à 60 s, borne de sûreté, choix non mesuré).
    var paddingSamples: Int {
        let seconds = config.padding.isFinite ? min(max(config.padding, 0), 60) : 0
        return Int((seconds * transcriberSampleRate).rounded())
    }

    // MARK: Écoute

    /// Une tranche du micro : ramenée à 16 kHz, donnée à la porte puis à la ligne de temps et au détecteur, bloc après bloc. Après
    /// chaque bloc, un passage fermé est pris pour un tour ou jeté, et la porte est consultée tant qu'un passage ouvert pendant que
    /// l'outil était occupé n'a pas encore coupé la parole.
    ///
    /// L'écoute est continue : pendant la transcription d'un tour, la réflexion et la parole aussi. C'est la porte, pas l'état, qui
    /// décide si ce qui est entendu alors devient un tour.
    func hear(_ chunk: AudioChunk) async {
        if resampler == nil || inputRate != chunk.sampleRate {
            guard let made = makeResampler(chunk.sampleRate, transcriberSampleRate) else {
                note(.microphone(ConversationFailure.Code.unusableSampleRate))
                return
            }
            resampler = made
            inputRate = chunk.sampleRate
        }
        guard let resampler else { return }
        let converted = resampler.push(chunk.samples)
        if resampler.hasFailed {
            note(.microphone(ConversationFailure.Code.conversionFailed))
            return
        }
        defer { emit(.level(AudioLevel.display(of: chunk.samples))) }
        gate.append(converted)
        timelineSamples += converted.count
        for block in timeline.append(converted) {
            let wasOpen = timeline.openSegmentStart != nil
            do {
                if let event = try await detector.process(block) { timeline.apply(event) }
            } catch {
                if !Task.isCancelled { note(.engine(ConversationFailure.Code.detectorFailed)) }
                return
            }
            if !wasOpen, timeline.openSegmentStart != nil { passageOrigin = isBusy ? .busy : .listening }
            settleClosedPassages()
            // Conclure, annuler ou une panne pendant l'attente du détecteur : la fin s'occupe du reste (un passage fermé est en file, un
            // passage ouvert a déjà tout l'audio de la tranche).
            if interruption() != nil { return }
            await consultGate()
        }
        // Une ligne de temps par passage : le passage fermé est traité, aucun n'est ouvert, l'écoute repart d'une ligne neuve (la
        // mémoire reste bornée à ce qui a été reçu depuis le dernier passage ou la dernière réplique).
        if timeline.openSegmentStart == nil, handledSegments > 0, handledSegments == timeline.closedSegments.count {
            await renew()
        }
    }

    /// Les passages fermés pas encore traités : un tour à transcrire, ou rien.
    func settleClosedPassages() {
        while handledSegments < timeline.closedSegments.count {
            let segment = timeline.closedSegments[handledSegments]
            handledSegments += 1
            let origin = passageOrigin
            passageOrigin = .listening
            switch origin {
            case .listening, .interrupting:
                clipsToTranscribe.append(timeline.clip(of: (segment.lowerBound - paddingSamples)..<(segment.upperBound + paddingSamples)))
            case .busy:
                break   // fermé sous le seuil pendant que l'outil était occupé : jamais transcrit
            case .rebased(let floor):
                // La porte, sur la seule partie du passage qui suit la fin de la parole (une trame qui finit après le passage ne
                // compte pas) ; elle implique `interruptMinDuration` au moins de cette partie.
                let from = max(floor, segment.lowerBound)
                guard gate.passes(from: from, to: segment.upperBound) else { break }
                clipsToTranscribe.append(timeline.clip(of: from..<(segment.upperBound + paddingSamples)))
            }
        }
    }

    /// La porte d'interruption, pour un passage ouvert pendant que l'outil était occupé. Quand elle dit oui, le passage devient un
    /// tour ; si l'outil réfléchissait ou parlait, la réplique est coupée et l'écoute reprend.
    func consultGate() async {
        guard passageOrigin == .busy, let start = timeline.openSegmentStart, gate.shouldInterrupt(passageStart: start) else { return }
        passageOrigin = .interrupting
        guard replyActive else { return }   // pendant la transcription, rien à couper : la réplique attendra ce passage
        await abortReply(interrupted: true)
        enterListening()
    }

    /// L'outil n'a plus rien en cours : un passage ouvert pendant qu'il était occupé ne compte plus qu'à partir d'ici.
    func becomeIdle() {
        if timeline.openSegmentStart != nil, passageOrigin == .busy { passageOrigin = .rebased(at: timelineSamples) }
        enterListening()
    }

    /// Le passage encore ouvert, à transcrire à la fin de l'entretien ; `nil` s'il ne compte pas.
    func openPassageClip() -> AudioClip? {
        guard let start = turnStartOfOpenPassage else { return nil }
        let clip = timeline.clip(of: start..<timelineSamples)
        return clip.samples.isEmpty ? nil : clip
    }

    /// Où commence le tour que forme le passage ouvert (remplissage compris) ; `nil` sans passage ouvert, ou s'il ne compte pas
    /// (encore) : un passage rebasé ne compte qu'une fois la porte passée sur ce qui suit la fin de la parole. L'aperçu et la fin de
    /// l'entretien passent par ici : ni l'un ni l'autre n'envoie l'écho au moteur de transcription.
    var turnStartOfOpenPassage: Int? {
        guard let start = timeline.openSegmentStart else { return nil }
        switch passageOrigin {
        case .listening, .interrupting: return max(start - paddingSamples, 0)
        case .busy: return nil
        case .rebased(let floor):
            let from = max(floor, start)
            return gate.passes(from: from, to: timelineSamples) ? from : nil
        }
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

    func stopPreview() async {
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil
    }

    func previewPass() async {
        // Le passage ouvert en entier (depuis le début de son tour), pour que le texte provisoire soit celui du passage et non de sa fin.
        guard let open = timeline.openSegmentStart, let start = turnStartOfOpenPassage else { return }
        let clip = timeline.clip(of: max(start, open)..<timelineSamples)
        guard !clip.samples.isEmpty else { return }
        let engine = transcriber
        let language = config.language
        let vocabulary = config.vocabulary
        // Bornée par `Deadline` : un moteur sourd à l'annulation ne retient pas l'écoute (qui attend cette passe) ni les passes suivantes.
        let text = try? await Deadline.run(seconds: config.transcriptionTimeout, sleep: transcriptionSleep) {
            try await engine.transcribe(clip, language: language, vocabulary: vocabulary)
        }
        // Le résultat d'une passe qui revient après la fermeture du passage, ou après l'écoute, ne se montre pas.
        guard let text, !Task.isCancelled, timeline.openSegmentStart == open else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { emit(.partialTranscript(trimmed)) }
    }

    // MARK: Transcription

    /// Lance la transcription d'un tour, dans une tâche à part bornée par `Deadline` (`transcriptionTimeout`) : un moteur sourd à
    /// l'annulation ne retient ni la boucle ni `cancel()`. Le résultat revient par le flux d'entrées ; la fin de l'entretien, elle,
    /// attend la tâche directement. Seul `cancel()` l'annule : `conclude()` et une panne du micro la laissent finir.
    func startTranscription(_ clip: AudioClip) {
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        let engine = transcriber
        let language = config.language
        let vocabulary = config.vocabulary
        let timeout = config.transcriptionTimeout
        let sleep = transcriptionSleep
        let inputs = inputSink
        let task = Task { () -> Result<String, any Error> in
            let result: Result<String, any Error>
            do {
                result = .success(try await Deadline.run(seconds: timeout, sleep: sleep) {
                    try await engine.transcribe(clip, language: language, vocabulary: vocabulary)
                })
            } catch {
                result = .failure(error)
            }
            inputs.yield(.transcribed(generation: generation, result))
            return result
        }
        transcription = (generation, task)
    }

    /// Le résultat d'une transcription : ce que la personne a dit entre dans la conversation (même si l'on conclut, annule ou tombe
    /// en panne ensuite). Un tour vide, quand rien d'autre de la personne n'attend, est un tour non compris. `closing` : la fin de
    /// l'entretien transcrit ce qui reste, sans avis ni reprise de l'écoute.
    func take(_ result: Result<String, any Error>, closing: Bool) {
        switch result {
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                conversation.appendUser(text)
                emit(.turnEnded(text))
                awaitingReply = true
                return
            }
            guard !closing, !isBusy, !interruptingPassageIsOpen else { return }
            emit(.notice(.notUnderstood))
            becomeIdle()
        case .failure(let error):
            transcriberUsable = false
            if error is CancellationError { return }   // seul `cancel()` annule une transcription
            // Une panne du micro déjà notée reste la première cause ; sinon c'est celle du moteur de transcription.
            note(.engine(error is DeadlineExceeded ? ConversationFailure.Code.transcriptionTimedOut : Self.transcriptionCode(of: error)))
        }
    }

    /// Annule la transcription en cours et l'attend (`Deadline` rend la main tout de suite, même avec un moteur sourd).
    func abandonTranscription() async {
        guard let running = transcription else { return }
        running.task.cancel()
        _ = await running.task.value
        transcription = nil
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
