import Foundation
import os

// La réplique de l'intervieweur : requête au modèle rapide, synthèse phrase par phrase, lecture, ce qui a été entendu.
extension ConversationChain {
    // MARK: Réplique

    /// Ce que la réplique laisse à la conversation.
    struct ReplyResult {
        var signal: ReplySignal
        var failure: RewriteFailure?
    }

    enum ModelEnd: Sendable {
        case done
        case failed(RewriteFailure)
        case cancelled
    }

    /// Les entrées de la réplique, dans un seul flux : le texte du modèle, la fin du modèle, la fin d'une synthèse, la fin d'un
    /// clip. Une seule tâche les lit, dans l'ordre : aucune course entre elles.
    enum ReplyInput: Sendable {
        case text(String)
        case modelEnded(ModelEnd)
        case synthesized(Int, Result<Speech, any Error>)
        case clipEnded(Int, PlaybackEnd)
    }

    enum SentenceOutcome {
        /// Mise en file de lecture, pas encore finie.
        case queued
        case played
        /// Coupée avant la fin : pas entendue.
        case stopped
        /// Affichée seule (plus de voix) : comptée comme entendue, elle a été montrée.
        case shown
        /// Rien à dire (la voix n'a rien rendu) : sautée, la voix reste.
        case skipped
    }

    struct ReplyState {
        var filter = ReplyFilter()
        var splitter = SentenceSplitter()
        /// Le texte visible cumulé, sans marqueur.
        var visible = ""
        var sentences: [String] = []
        var outcomes: [Int: SentenceOutcome] = [:]
        var queue = SpeechQueue()
        var modelEnd: ModelEnd?
        var started = false
        /// Le nombre de questions qui restaient quand la requête est partie.
        var remainingAtStart = 0

        var isComplete: Bool { modelEnd != nil && queue.isIdle }
    }

    /// L'état de la réplique en cours, pour les tests : l'appel passe derrière le tour d'acteur qui vient de le modifier.
    func replySnapshot() -> ReplySnapshot {
        ReplySnapshot(queuedClips: reply.queue.queuedClips, synthesizing: reply.queue.synthesizing, pending: reply.queue.pending)
    }

    /// Une requête au modèle rapide, puis sa réplique dite phrase par phrase. Rend la main quand le modèle a fini, que plus rien
    /// n'est à synthétiser et que tous les clips en file ont fini, ou dès que la tâche est annulée (la réplique est alors rangée :
    /// requête et synthèse annulées, lecture coupée, ce qui a été joué est compté).
    func speak(remaining: Int) async -> ReplyResult {
        guard let completion = conversation.completion() else {
            return ReplyResult(signal: .continue, failure: .empty)   // jamais : le dernier tour est celui de la personne
        }
        let (inputs, inputSink) = AsyncStream<ReplyInput>.makeStream()
        let tracker = ReplyPlayback()
        reply = ReplyState(remainingAtStart: remaining)
        replyInputs = inputSink
        replyTracker = tracker

        let model = fastModel
        let name = config.fastModel
        let policy = config.turnPolicy
        let instruction = InterviewPrompt.instruction(remainingQuestions: remaining)
        let modelTask = Task {
            do {
                _ = try await Rewriter.run(model, model: name, instruction: instruction, input: completion.input,
                                           history: completion.history, policy: policy) { inputSink.yield(.text($0)) }
                inputSink.yield(.modelEnded(.done))
            } catch is CancellationError {
                inputSink.yield(.modelEnded(.cancelled))
            } catch let failure as RewriteFailure {
                inputSink.yield(.modelEnded(.failed(failure)))
            } catch {
                inputSink.yield(.modelEnded(.failed(.from(error))))
            }
        }

        for await input in inputs {
            handle(input)
            advance()
            if reply.isComplete { break }
        }

        // Rangement, quelle que soit la façon de finir : ce qui produit est arrêté et attendu avant ce qui consomme.
        modelTask.cancel()
        await modelTask.value
        synthesisTask?.cancel()
        await synthesisTask?.value
        synthesisTask = nil
        if tracker.outstanding > 0 {
            audio.stopPlayback()
            await tracker.waitUntilIdle()
        }
        for (index, end) in tracker.ends.sorted(by: { $0.key < $1.key }) where reply.outcomes[index] == .queued {
            finishClip(index, end)
        }

        let heard = reply.sentences.indices
            .filter { reply.outcomes[$0] == .played || reply.outcomes[$0] == .shown }
            .map { reply.sentences[$0] }
            .joined(separator: " ")
        conversation.appendInterviewer(heard)
        if reply.started { emit(.speakingEnded(heard: heard)) }

        var failure: RewriteFailure?
        if case .failed(let reason)? = reply.modelEnd { failure = reason }
        let signal = reply.filter.signal
        // Une réplique dont aucune phrase n'a été dite ni montrée (le marqueur seul, ou des phrases sans rien à dire) n'est pas une
        // question : c'est un modèle qui n'a rien dit. Dès qu'une phrase a été dite ou montrée, elle reste.
        let spoken = reply.sentences.indices.contains { reply.outcomes[$0] == .played || reply.outcomes[$0] == .shown }
        if case .done? = reply.modelEnd, !spoken, signal != .conclude { failure = .empty }
        replyInputs = nil
        replyTracker = nil
        reply = ReplyState()
        return ReplyResult(signal: signal, failure: failure)
    }

    func handle(_ input: ReplyInput) {
        switch input {
        case .text(let visible):
            absorb(reply.filter.feed(visible))
        case .modelEnded(let end):
            if case .done = end {
                // La fin du texte : ce que le filtre retenait, puis la dernière phrase que le découpeur gardait.
                absorb(reply.filter.finish())
                if let last = reply.splitter.flush() { addSentence(last) }
            }
            reply.modelEnd = end
        case .synthesized(let index, let result):
            reply.queue.synthesisFinished()
            deliver(index, result)
        case .clipEnded(let index, let end):
            reply.queue.clipEnded()
            finishClip(index, end)
        }
    }

    func absorb(_ delta: String) {
        guard !delta.isEmpty else { return }
        reply.visible += delta
        emit(.replyText(reply.visible))
        for sentence in reply.splitter.feed(delta) { addSentence(sentence) }
    }

    func addSentence(_ text: String) {
        _ = reply.queue.register()
        reply.sentences.append(text)
    }

    /// Lance la synthèse de la phrase suivante si la file le permet ; sans voix, affiche les phrases en attente.
    func advance() {
        if !voiceUsable {
            for index in reply.queue.takeAllPending() { show(index) }
        } else if let index = reply.queue.nextToSynthesize(), let inputs = replyInputs {
            let text = reply.sentences[index]
            let voice = voice
            synthesisTask = Task {
                do {
                    inputs.yield(.synthesized(index, .success(try await voice.synthesize(text))))
                } catch {
                    inputs.yield(.synthesized(index, .failure(error)))
                }
            }
        }
    }

    func deliver(_ index: Int, _ result: Result<Speech, any Error>) {
        switch result {
        case .failure(let error):
            // Rien à dire n'est la panne d'aucune voix : la phrase est sautée. Une synthèse annulée aussi (la réplique se range).
            if error is CancellationError || (error as? SpeechError) == .empty {
                reply.outcomes[index] = .skipped
                return
            }
            voiceDown()
            show(index)
        case .success(let speech):
            if speech.fellBack, !announcedFallback {
                announcedFallback = true
                emit(.notice(.voiceFellBack))
            }
            guard let tracker = replyTracker, let inputs = replyInputs else { return }
            tracker.reserve()
            do {
                try audio.play(speech.clip) { end in
                    tracker.ended(index, end)
                    inputs.yield(.clipEnded(index, end))
                }
            } catch {
                tracker.release()
                voiceDown()
                show(index)
                return
            }
            reply.queue.clipQueued()
            reply.outcomes[index] = .queued
            beginSpeaking()
        }
    }

    /// Plus de voix : un avis, une seule fois par entretien, puis le texte seul jusqu'à la fin.
    func voiceDown() {
        guard voiceUsable else { return }
        voiceUsable = false
        emit(.notice(.voiceUnavailable))
    }

    func show(_ index: Int) {
        reply.outcomes[index] = .shown
        beginSpeaking()
    }

    func finishClip(_ index: Int, _ end: PlaybackEnd) {
        switch end {
        case .played:
            reply.outcomes[index] = .played
            emit(.sentencePlayed(reply.sentences[index]))
        case .stopped:
            reply.outcomes[index] = .stopped
        }
    }

    /// La première phrase de la réplique est mise en file (ou affichée) : la question compte, avec les avis qui la concernent.
    func beginSpeaking() {
        guard !reply.started else { return }
        reply.started = true
        let signal = reply.filter.signal
        if signal != .conclude {
            questionsAsked += 1
            if reply.remainingAtStart == 1 { emit(.notice(.lastQuestion)) }
            if signal == .propose { emit(.notice(.proposal)) }
        }
        emit(.state(.speaking))
        emit(.speakingStarted(question: questionsAsked))
    }
}
