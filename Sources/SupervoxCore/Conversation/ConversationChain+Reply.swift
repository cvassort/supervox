import Foundation
import os

// La réplique de l'intervieweur : requête au modèle rapide, synthèse phrase par phrase, lecture, ce qui a été entendu.
extension ConversationChain {
    // MARK: Réplique

    enum ModelEnd: Sendable {
        case done
        case failed(RewriteFailure)
        case cancelled
    }

    /// Les entrées de la réplique, dans le flux de l'entretien : le texte du modèle, la fin du modèle, la fin d'une synthèse, la fin
    /// d'un clip.
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
        /// Coupée avant la moitié de sa durée : pas entendue.
        case stopped
        /// Coupée après la moitié au moins de sa durée (`cutSentenceHeardFraction`) : comptée comme entendue, en entier (revue de la
        /// tâche 6, m-9). Pas de `.sentencePlayed` : elle n'a pas été jouée jusqu'au bout.
        case mostlyPlayed
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
        /// La durée de chaque clip mis en file, en secondes (pour savoir quelle part d'une phrase coupée a été jouée).
        var durations: [Int: Double] = [:]
        /// La question de cette réplique a été comptée (`beginSpeaking`) : défait si rien n'en a été entendu (m-10).
        var countedQuestion = false
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

    /// Une phrase coupée compte comme entendue si au moins cette part de sa durée a été jouée (choix du contrôleur au tour de
    /// correction 1 de la tâche 6 ; choix non mesuré).
    static let cutSentenceHeardFraction = 0.5

    /// Comment une réplique se termine.
    enum ReplyClosing {
        /// Le modèle a fini, plus rien n'est à synthétiser, tous les clips ont fini.
        case complete
        /// La personne a coupé la parole (la porte d'interruption a dit oui).
        case interrupted
        /// L'entretien se termine (conclusion, panne, annulation).
        case ended
    }

    /// Une requête au modèle rapide, dont la réplique sera dite phrase par phrase. Ses entrées arrivent par le flux de l'entretien,
    /// sous un numéro de génération neuf.
    func startReply(remaining: Int) {
        guard let completion = conversation.completion() else {
            // Jamais : le dernier tour est celui de la personne. Traité comme un modèle qui n'a rien dit.
            emit(.notice(.modelFailed(.empty)))
            becomeIdle()
            return
        }
        replyGeneration += 1
        let generation = replyGeneration
        reply = ReplyState(remainingAtStart: remaining)
        replyActive = true
        replyTracker = ReplyPlayback()
        emit(.state(.thinking))

        let inputs = inputSink
        let model = fastModel
        let name = config.fastModel
        let policy = config.turnPolicy
        let instruction = InterviewPrompt.instruction(remainingQuestions: remaining)
        modelTask = Task {
            let end: ModelEnd
            do {
                _ = try await Rewriter.run(model, model: name, instruction: instruction, input: completion.input,
                                           history: completion.history, policy: policy) {
                    inputs.yield(.reply(generation: generation, .text($0)))
                }
                end = .done
            } catch is CancellationError {
                end = .cancelled
            } catch let failure as RewriteFailure {
                end = .failed(failure)
            } catch {
                end = .failed(.from(error))
            }
            inputs.yield(.reply(generation: generation, .modelEnded(end)))
        }
    }

    /// La réplique est finie d'elle-même. Rend `.concluding` si l'intervieweur conclut ; sinon l'écoute reprend (`nil`).
    func finishReply() async -> TalkOutcome? {
        let result = await closeReply(.complete)
        if let stop = interruption() { return stop }
        if result.signal == .conclude { return .concluding }
        if let failure = result.failure { emit(.notice(.modelFailed(failure))) }
        if timeline.openSegmentStart == nil { await renew() }   // une ligne de temps neuve, sauf si la personne parle déjà
        if let stop = interruption() { return stop }
        becomeIdle()
        return nil
    }

    /// Coupe la réplique en cours : par la personne (`interrupted`), ou parce que l'entretien se termine.
    func abortReply(interrupted: Bool) async {
        let heard = await closeReply(interrupted ? .interrupted : .ended).heard
        // Coupée avant toute phrase entendue, la réplique n'a pas répondu au tour de la personne : il attend toujours sa réplique,
        // et ce qu'elle dit ensuite lui est fusionné (la conversation joint deux tours de suite du même côté).
        if interrupted { awaitingReply = heard.isEmpty }
    }

    /// Range la réplique : ce qui produit est arrêté et attendu avant ce qui consomme, la lecture est coupée si des clips sont en
    /// file, et seules les phrases entendues entrent dans la conversation : jouées jusqu'au bout, coupées après la moitié au moins de
    /// leur durée (`.mostlyPlayed`), ou montrées. Le numéro de génération change
    /// **avant** la première attente : ce qui reste de cette réplique dans le flux (texte, synthèse, fin de clip) est jeté à la lecture,
    /// et ne lance plus aucune synthèse ni lecture.
    func closeReply(_ closing: ReplyClosing) async -> (heard: String, signal: ReplySignal, failure: RewriteFailure?) {
        replyActive = false
        replyGeneration += 1
        let tracker = replyTracker
        modelTask?.cancel()
        await modelTask?.value
        modelTask = nil
        synthesisTask?.cancel()
        await synthesisTask?.value
        synthesisTask = nil
        var mostlyPlayed: Int?
        if let tracker, tracker.outstanding > 0 {
            // La position du clip en cours se lit AVANT l'arrêt (après, plus aucun clip n'est en cours). Le clip en cours est le
            // premier en file dont la fin n'est pas encore arrivée ; s'il finit de lui-même avant l'arrêt, sa fin est `.played` et la
            // position ne sert à rien.
            // Les fins se lisent AVANT la position (revue finale, m-A) : les fins arrivent par la file de livraison, après le registre
            // qui donne la position, donc cet instantané est toujours en retard sur elle. Un clip qui finit entre les deux lectures
            // reste le clip en cours, avec sa propre position (sa fin `.played` arrive ensuite) ; lues dans l'autre ordre, sa position
            // serait attribuée au clip suivant, à peine commencé, et le ferait compter comme entendu.
            let ended = tracker.ends
            let playing = reply.outcomes.filter { $0.value == .queued && ended[$0.key] == nil }.map(\.key).min()
            let position = audio.playbackPosition
            audio.stopPlayback()
            await tracker.waitUntilIdle()
            if let playing, let position, let duration = reply.durations[playing], duration > 0,
               position >= duration * Self.cutSentenceHeardFraction {
                mostlyPlayed = playing
            }
        }
        for (index, end) in (tracker?.ends ?? [:]).sorted(by: { $0.key < $1.key }) where reply.outcomes[index] == .queued {
            finishClip(index, end)
        }
        if let mostlyPlayed, reply.outcomes[mostlyPlayed] == .stopped { reply.outcomes[mostlyPlayed] = .mostlyPlayed }

        let heard = reply.sentences.indices
            .filter { reply.outcomes[$0].map(Self.isHeard) ?? false }
            .map { reply.sentences[$0] }
            .joined(separator: " ")
        // Une question dont rien n'a été entendu (coupée avant la moitié de sa première phrase) ne compte pas (m-10).
        if reply.countedQuestion, heard.isEmpty { questionsAsked -= 1 }
        conversation.appendInterviewer(heard)
        switch closing {
        case .interrupted: emit(.interrupted(heard: heard))
        case .complete, .ended: if reply.started { emit(.speakingEnded(heard: heard)) }
        }

        var failure: RewriteFailure?
        if case .failed(let reason)? = reply.modelEnd { failure = reason }
        let signal = reply.filter.signal
        // Une réplique dont aucune phrase n'a été dite ni montrée (le marqueur seul, ou des phrases sans rien à dire) n'est pas une
        // question : c'est un modèle qui n'a rien dit. Dès qu'une phrase a été dite ou montrée, elle reste.
        let spoken = reply.sentences.indices.contains { reply.outcomes[$0].map(Self.isHeard) ?? false }
        if case .done? = reply.modelEnd, !spoken, signal != .conclude { failure = .empty }
        replyTracker = nil
        reply = ReplyState()
        return (heard, signal, failure)
    }

    /// Une phrase entendue : jouée jusqu'au bout, jouée au-delà de la moitié puis coupée, ou montrée.
    static func isHeard(_ outcome: SentenceOutcome) -> Bool {
        switch outcome {
        case .played, .mostlyPlayed, .shown: true
        case .queued, .stopped, .skipped: false
        }
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
        advance()
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
        } else if let index = reply.queue.nextToSynthesize() {
            // Garde d'indice : la garde de génération écarte déjà toute entrée d'une réplique abandonnée ; un glissement futur doit
            // échouer sans planter le processus (revue de la tâche 6, m-1). La phrase est sautée et la file libérée : sans cela,
            // elle resterait « en synthèse » et la réplique ne finirait jamais (revue finale, m-C).
            guard reply.sentences.indices.contains(index) else {
                reply.queue.synthesisFinished()
                reply.outcomes[index] = .skipped
                return
            }
            let text = reply.sentences[index]
            let voice = voice
            let inputs = inputSink
            let generation = replyGeneration
            synthesisTask = Task {
                do {
                    inputs.yield(.reply(generation: generation, .synthesized(index, .success(try await voice.synthesize(text)))))
                } catch {
                    inputs.yield(.reply(generation: generation, .synthesized(index, .failure(error))))
                }
            }
        }
    }

    func deliver(_ index: Int, _ result: Result<Speech, any Error>) {
        guard reply.sentences.indices.contains(index) else { return }   // une phrase qui n'existe pas : ignorée (m-1)
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
            guard let tracker = replyTracker else { return }
            let inputs = inputSink
            let generation = replyGeneration
            tracker.reserve()
            do {
                try audio.play(speech.clip) { end in
                    tracker.ended(index, end)
                    inputs.yield(.reply(generation: generation, .clipEnded(index, end)))
                }
            } catch {
                tracker.release()
                voiceDown()
                show(index)
                return
            }
            reply.queue.clipQueued()
            reply.outcomes[index] = .queued
            reply.durations[index] = speech.clip.sampleRate > 0 ? Double(speech.clip.samples.count) / speech.clip.sampleRate : 0
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
        guard reply.sentences.indices.contains(index) else { return }   // une phrase qui n'existe pas : ignorée, sans planter (m-1)
        switch end {
        case .played:
            reply.outcomes[index] = .played
            emit(.sentencePlayed(reply.sentences[index]))
        case .stopped:
            reply.outcomes[index] = .stopped
        }
    }

    /// La première phrase de la réplique commence à être jouée (ou est affichée) : la question compte, avec les avis qui la
    /// concernent. Si rien n'en est finalement entendu (coupée avant la moitié de sa première phrase), `closeReply` défait ce compte ;
    /// `.speakingStarted(question:)` et `.lastQuestion` ont alors déjà été émis, et le même numéro reviendra à la question suivante. Le premier clip d'une réplique part dès `play()` : la file de lecture est vide, la réplique précédente a attendu
    /// la fin de tous ses clips (code lu ; l'`AudioIO` ne signale pas le début d'un clip). Coupée avant, la question ne compte pas.
    func beginSpeaking() {
        guard !reply.started else { return }
        reply.started = true
        let signal = reply.filter.signal
        if signal != .conclude {
            questionsAsked += 1
            reply.countedQuestion = true
            if reply.remainingAtStart == 1 { emit(.notice(.lastQuestion)) }
            if signal == .propose { emit(.notice(.proposal)) }
        }
        emit(.state(.speaking))
        emit(.speakingStarted(question: questionsAsked))
    }
}
