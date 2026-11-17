import AppKit
import Foundation
import SupervoxCore
import SwiftUI
import Testing

@testable import SupervoxApp

// Ce que la vue de l'entretien montre, état par état (tâche 8 du plan « entretien », règles 2, 4 et 5). Tout ce qui se décide sans
// dessiner est testé sur `InterviewViewState` ; la vue SwiftUI ne fait que l'afficher, et ses images sont comparées entre elles
// (même méthode que `DictationViewTests`).

@MainActor @Suite struct InterviewViewStateTests {
    private func state(
        _ phase: InterviewPhase = .listening, question: Int = 0, max: Int = 6, questionText: String = "", lastReply: String = "",
        level: Float = 0, notice: String? = nil, holdNote: Bool = false
    ) -> InterviewViewState {
        var state = InterviewViewState(maxQuestions: max, privacy: "La vie privée.")
        state.phase = phase
        state.question = question
        state.questionText = questionText
        state.lastReply = lastReply
        state.level = level
        state.notice = notice
        state.holdNote = holdNote
        return state
    }

    // MARK: Règle 2 : état → vue

    @Test("règle 2 : chaque état du moteur a sa phase, et seul « terminé » n'en a pas")
    func everyEngineStateHasAPhaseExceptFinished() {
        #expect(InterviewPhase(.preparing) == .preparing)
        #expect(InterviewPhase(.listening) == .listening)
        #expect(InterviewPhase(.thinking) == .thinking)
        #expect(InterviewPhase(.speaking) == .speaking)
        #expect(InterviewPhase(.concluding) == .concluding)
        #expect(InterviewPhase(.finished) == nil)
    }

    @Test("règle 2 : chaque phase a son titre, et deux phases n'ont jamais le même")
    func everyPhaseHasItsOwnTitle() {
        let titles = InterviewTextTests.phases.map { state($0).title }
        #expect(titles == InterviewTextTests.phases.map { InterviewText.title($0) })
        #expect(Set(titles).count == titles.count)
        #expect(!titles.contains(""))
    }

    @Test func aNewInterviewStartsInPreparationWithNothingShown() {
        let fresh = InterviewViewState(maxQuestions: 5, privacy: "Texte.")
        #expect(fresh.phase == .preparing)
        #expect(fresh.question == 0 && fresh.maxQuestions == 5)
        #expect(fresh.questionText.isEmpty && fresh.lastReply.isEmpty)
        #expect(fresh.level == 0 && fresh.notice == nil && !fresh.holdNote)
        #expect(fresh.privacy == "Texte.")
        #expect(fresh.counter == nil)
    }

    @Test("règle 2 : rien avant la première question, y compris la réplique de conclusion qui porte le numéro 0")
    func nothingIsCountedBeforeTheFirstQuestion() {
        // `.speakingStarted(question: 0)` : la réplique de conclusion avant toute question.
        #expect(state(.speaking, question: 0).counter == nil)
        #expect(state(.speaking, question: -1).counter == nil)
        #expect(state(.speaking, question: 1).counter == "Question 1 sur 6")
        #expect(state(.listening, question: 3, max: 8).counter == "Question 3 sur 8")
        #expect(state(.concluding, question: 6).counter == "Question 6 sur 6")
    }

    @Test("l'aide suit la phase : aucune en préparation ni en conclusion")
    func theHintFollowsThePhase() {
        #expect(state(.preparing).hint == nil)
        #expect(state(.concluding).hint == nil)
        #expect(state(.listening).hint == InterviewText.hint(.listening))
        #expect(state(.thinking).hint == InterviewText.hint(.thinking))
        #expect(state(.speaking).hint == InterviewText.hint(.speaking))
    }

    @Test("le pied « Échap annule » est là à tout état sauf la conclusion")
    func theCancelHintIsShownExceptWhileConcluding() {
        for phase in InterviewTextTests.phases {
            #expect(state(phase).cancelHint == (phase == .concluding ? nil : InterviewText.cancelHint), "\(phase)")
        }
    }

    @Test("la note de maintien n'est montrée que si le réglage est « maintien »")
    func theHoldNoteFollowsTheSetting() {
        #expect(state(holdNote: true).shownHoldNote == InterviewText.holdNote)
        #expect(state(holdNote: false).shownHoldNote == nil)
    }

    @Test("la dernière réplique blanche n'est pas montrée, celle qui a un texte l'est")
    func aBlankLastReplyIsNotShown() {
        #expect(state(lastReply: "").shownReply == nil)
        #expect(state(lastReply: " \n ").shownReply == nil)
        #expect(state(lastReply: "Je voudrais un résumé.").shownReply == "Je voudrais un résumé.")
    }

    @Test("I6 : l'état garde le texte entier de la réplique et de la réponse, rien n'est coupé par le début")
    func theStateKeepsTheWholeText() throws {
        let long = Array(repeating: "mot", count: 2_000).joined(separator: " ") + " fin"
        var long1 = state(questionText: long, lastReply: long)
        #expect(long1.questionText == long && long1.lastReply == long)
        #expect(try #require(long1.shownReply) == long, "la réponse montrée est coupée")
        long1.questionText = "Début. " + long
        #expect(long1.questionText.hasPrefix("Début."))
    }

    @Test("M8 : sans voix (texte seul) la parole prend un autre titre et une autre aide ; avec voix rien ne change")
    func aTextOnlyInterviewRenamesTheSpeakingPhase() {
        var text = state(.speaking)
        #expect(text.title == "Supervox parle" && text.hint == InterviewText.hint(.speaking))
        text.textOnly = true
        #expect(text.title == "Supervox répond")
        #expect(text.hint == "Lisez la réponse à l'écran, puis parlez.")
        #expect(InterviewViewState(maxQuestions: 3, privacy: "x").textOnly == false)
        var listening = state(.listening)
        listening.textOnly = true
        #expect(listening.title == "À vous", "le texte seul ne change que la phase de parole")
    }

    // MARK: Règle 4 : Conclure

    @Test("règle 4 : « Conclure » est grisé en préparation et en conclusion, actif ailleurs")
    func concludeIsDisabledOnlyWhilePreparingAndConcluding() {
        for phase in InterviewTextTests.phases {
            #expect(state(phase).canConclude == (phase != .preparing && phase != .concluding), "\(phase)")
        }
    }

    /// Le bouton reçoit l'état de l'entretien : il lit `canConclude` au seul endroit qui le calcule, aucun booléen libre.
    private func concludeImage(_ phase: InterviewPhase, key: Bool = true) throws -> Data {
        try image(
            of: ConcludeButton(state: state(phase), action: {}).frame(width: 200)
                .environment(\.controlActiveState, key ? .key : .inactive))
    }

    @Test("règle 4, I2 : « Conclure » se dessine grisé en préparation et en conclusion, actif en écoute, réflexion et parole")
    func theButtonFollowsThePhaseOfTheState() throws {
        let active = try concludeImage(.listening)
        #expect(try concludeImage(.listening) == active, "le rendu n'est pas reproductible")
        for phase in [InterviewPhase.thinking, .speaking] {
            #expect(try concludeImage(phase) == active, "\(phase) : le bouton devrait être actif")
        }
        for phase in [InterviewPhase.preparing, .concluding] {
            #expect(try concludeImage(phase) != active, "\(phase) : le bouton devrait être grisé")
        }
        #expect(try concludeImage(.preparing) == concludeImage(.concluding))
    }

    @Test("I5 : « Conclure » actif et grisé restent distincts, et ne dépendent pas de l'état clé de la fenêtre")
    func theButtonLooksTheSameWhetherTheWindowIsKeyOrNot() throws {
        for phase in [InterviewPhase.listening, .preparing] {
            #expect(try concludeImage(phase, key: true) == concludeImage(phase, key: false), "\(phase) : l'aspect suit la fenêtre")
        }
        #expect(try concludeImage(.listening, key: false) != concludeImage(.preparing, key: false))
    }

    @Test("règle 3 : les pastilles verrouillées ne se dessinent pas comme les pastilles actives")
    func lockedChipsLookDisabled() throws {
        func chips(locked: Bool) throws -> Data {
            try image(of: ModeChips(modes: ModeChip.fixed, selectedID: "prompt", locked: locked, select: { _ in }).frame(width: 488))
        }
        #expect(try chips(locked: false) == chips(locked: false), "le rendu n'est pas reproductible")
        #expect(try chips(locked: true) != chips(locked: false))
    }

    @Test("M6 : une pastille verrouillée et non choisie dit pourquoi à VoiceOver ; la choisie et les actives, rien")
    func aLockedChipExplainsItself() {
        #expect(ModeChips.accessibilityHint(locked: true, isSelected: false) == "Indisponible pendant un entretien.")
        #expect(ModeChips.accessibilityHint(locked: true, isSelected: true) == nil)
        #expect(ModeChips.accessibilityHint(locked: false, isSelected: false) == nil)
        #expect(ModeChips.accessibilityHint(locked: false, isSelected: true) == nil)
    }

    // MARK: Règle 5 : l'orbe

    @Test("I3, règle 5 : l'orbe porte le titre de l'état comme libellé et n'est pas un élément interactif")
    func theOrbCarriesTheTitleAndIsNotInteractive() {
        var states = InterviewTextTests.phases.map { state($0) }
        var textOnly = state(.speaking)
        textOnly.textOnly = true
        states.append(textOnly)
        for state in states {
            let spec = OrbAccessibility(title: state.title)
            #expect(spec.label == state.title, "\(state.phase)")
            #expect(!spec.traits.contains(.isButton) && !spec.traits.contains(.isLink) && !spec.traits.contains(.isToggle))
            #expect(spec.traits.contains(.isImage))
        }
    }

    @Test("I8 : seule l'écoute suit le niveau du micro (borné, NaN lu comme le silence) ; la parole et l'attente l'ignorent")
    func onlyListeningFollowsTheMicrophone() {
        let silent = OrbAppearance(level: 0, phase: .listening, reduceMotion: false)
        let loud = OrbAppearance(level: 1, phase: .listening, reduceMotion: false)
        let middle = OrbAppearance(level: 0.5, phase: .listening, reduceMotion: false)
        #expect(silent.scale == 1)
        #expect(loud.scale > middle.scale && middle.scale > silent.scale)
        #expect(OrbAppearance(level: 7, phase: .listening, reduceMotion: false) == loud)
        #expect(OrbAppearance(level: -3, phase: .listening, reduceMotion: false) == silent)
        #expect(OrbAppearance(level: .nan, phase: .listening, reduceMotion: false) == silent)
        #expect(OrbAppearance(level: .infinity, phase: .listening, reduceMotion: false) == loud)
        for phase in [InterviewPhase.preparing, .thinking, .speaking, .concluding] {
            for reduce in [false, true] {
                let quiet = OrbAppearance(level: 0, phase: phase, reduceMotion: reduce)
                let noisy = OrbAppearance(level: 1, phase: phase, reduceMotion: reduce)
                #expect(quiet == noisy, "\(phase) (mouvement réduit : \(reduce)) : l'orbe suit le micro")
                #expect(quiet.scale == 1, "\(phase)")
            }
        }
    }

    @Test("règle 5 : avec « Réduire les animations » l'orbe d'écoute reste fixe, seule l'opacité suit le niveau")
    func withReducedMotionTheListeningOrbIsFixedAndOnlyItsOpacityFollowsTheLevel() {
        let silent = OrbAppearance(level: 0, phase: .listening, reduceMotion: true)
        let middle = OrbAppearance(level: 0.5, phase: .listening, reduceMotion: true)
        let loud = OrbAppearance(level: 1, phase: .listening, reduceMotion: true)
        #expect(silent.scale == 1 && middle.scale == 1 && loud.scale == 1)
        #expect(loud.opacity > middle.opacity && middle.opacity > silent.opacity)
        #expect(silent.opacity > 0, "l'orbe ne disparaît jamais")
        #expect(OrbAppearance(level: .nan, phase: .listening, reduceMotion: true) == silent)
        #expect(loud.opacity <= 1)
    }

    @Test("une phase d'attente éteint l'orbe ; l'écoute et la parole sont pleines")
    func aWaitingPhaseDimsTheOrb() {
        for reduce in [false, true] {
            let live = OrbAppearance(level: 1, phase: .listening, reduceMotion: reduce)
            #expect(OrbAppearance(level: 1, phase: .speaking, reduceMotion: reduce).opacity == live.opacity)
            for phase in [InterviewPhase.preparing, .thinking, .concluding] {
                #expect(OrbAppearance(level: 1, phase: phase, reduceMotion: reduce).opacity < live.opacity, "\(phase)")
            }
        }
    }

    @Test("I8 : l'orbe dit qui a la parole par son symbole : micro en écoute, onde en parole, attente sinon ; symboles du système")
    func theOrbSymbolSaysWhoHasTheFloor() {
        func symbol(_ phase: InterviewPhase, textOnly: Bool = false) -> String {
            OrbAppearance(level: 0.5, phase: phase, textOnly: textOnly, reduceMotion: false).symbol
        }
        #expect(symbol(.listening) == "mic.fill")
        #expect(symbol(.speaking) == "waveform")
        #expect(symbol(.speaking, textOnly: true) == "text.bubble.fill", "sans voix, rien ne parle : pas d'onde")
        for phase in [InterviewPhase.preparing, .thinking, .concluding] { #expect(symbol(phase) == "ellipsis", "\(phase)") }
        let all = Set(InterviewTextTests.phases.map { symbol($0) } + [symbol(.speaking, textOnly: true)])
        #expect(all.count == 4)
        for name in all {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) n'est pas un symbole du système")
        }
    }

    @Test("M1 : un signe d'activité lent pendant la conclusion seulement, arrêté sous « Réduire les animations »")
    func onlyTheConclusionPulsesAndNotWhenMotionIsReduced() {
        for phase in InterviewTextTests.phases {
            for reduce in [false, true] {
                let pulses = OrbAppearance(level: 0, phase: phase, reduceMotion: reduce).pulses
                #expect(pulses == (phase == .concluding && !reduce), "\(phase), mouvement réduit : \(reduce)")
            }
        }
    }

    /// La silhouette de l'orbe : le plus petit rectangle qui contient un pixel non transparent, et les pixels eux-mêmes.
    private struct Rendering: Equatable {
        var box: CGRect
        var size: CGSize
        var png: Data
    }

    private func orb(level: Float, phase: InterviewPhase = .listening, reduceMotion: Bool) throws -> Rendering {
        let host = // Les 16 points de marge du panneau (`PanelView.padding`) : l'orbe est alignée sur la colonne des textes par un décalage de
        // -8 points, son halo le plus grand déborde donc de son cadre dans cette marge.
        NSHostingView(rootView: InterviewOrb(state: state(phase, level: level), reduceMotion: reduceMotion).padding(16))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var box = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return Rendering(
            box: box, size: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
            png: try #require(bitmap.representation(using: .png, properties: [:])))
    }

    @Test("règle 5 : dessinée, l'orbe d'écoute grandit avec le niveau ; avec « Réduire les animations » sa silhouette ne bouge pas")
    func theDrawnOrbGrowsWithTheLevelUnlessMotionIsReduced() throws {
        let silent = try orb(level: 0, reduceMotion: false)
        let loud = try orb(level: 1, reduceMotion: false)
        #expect(!silent.box.isNull, "l'orbe n'est pas dessinée")
        #expect(loud.box.width > silent.box.width && loud.box.height > silent.box.height, "l'orbe ne grandit pas")

        let fixedSilent = try orb(level: 0, reduceMotion: true)
        let fixedLoud = try orb(level: 1, reduceMotion: true)
        #expect(fixedSilent.box == fixedLoud.box, "l'orbe bouge malgré « Réduire les animations »")
        #expect(fixedSilent.png != fixedLoud.png, "l'intensité ne passe pas par l'opacité")
        #expect(fixedSilent.box == silent.box, "l'orbe fixe est l'orbe au repos")
    }

    @Test("I8 : dessinée, l'orbe de parole ne bouge pas avec le micro, et ne ressemble pas à celle d'écoute")
    func theDrawnSpeakingOrbIgnoresTheMicrophoneAndDiffersFromListening() throws {
        let quiet = try orb(level: 0, phase: .speaking, reduceMotion: false)
        let noisy = try orb(level: 1, phase: .speaking, reduceMotion: false)
        #expect(quiet == noisy, "l'orbe de parole suit le micro")
        #expect(try orb(level: 0, phase: .listening, reduceMotion: false).png != quiet.png, "écoute et parole se ressemblent")
    }

    @Test("l'orbe, au niveau le plus fort, n'est coupée par aucun bord de son cadre")
    func theLoudestOrbIsNotClippedByItsFrame() throws {
        let loud = try orb(level: 1, phase: .listening, reduceMotion: false)
        #expect(loud.box.minX > 0 && loud.box.minY > 0, "\(loud.box) dans \(loud.size)")
        #expect(loud.box.maxX < loud.size.width && loud.box.maxY < loud.size.height, "\(loud.box) dans \(loud.size)")
    }

    // MARK: Règle 5 : l'annonce VoiceOver

    @Test("règle 5 : le titre change, l'annonce est le nouveau titre ; le même titre ne s'annonce pas deux fois")
    func aNewTitleIsAnnouncedAndTheSameTitleIsNot() {
        #expect(InterviewViewState.announcements(from: nil, to: state(.preparing)) == ["Préparation de l'entretien…"])
        #expect(InterviewViewState.announcements(from: state(.preparing), to: state(.listening)) == ["À vous"])
        #expect(InterviewViewState.announcements(from: state(.listening), to: state(.thinking)) == ["Réflexion…"])
        // Le niveau, la question, les textes changent sans cesse : aucun ne change le titre.
        let before = state(.listening, question: 1, level: 0.1)
        let after = state(.listening, question: 2, questionText: "Autre ?", lastReply: "Oui.", level: 0.9)
        #expect(InterviewViewState.announcements(from: before, to: after).isEmpty)
        #expect(InterviewViewState.announcements(from: state(.speaking), to: nil).isEmpty)
        #expect(InterviewViewState.announcements(from: nil, to: nil).isEmpty)
    }

    @Test("I4 : un avis est annoncé une fois, quand il apparaît ; pas à chaque niveau ; de nouveau s'il revient après avoir été effacé")
    func aNoticeIsAnnouncedOncePerAppearance() {
        let plain = state(.listening)
        let noticed = state(.listening, notice: "Rien n'a été compris.")
        #expect(InterviewViewState.announcements(from: plain, to: noticed) == ["Rien n'a été compris."])
        var louder = noticed
        louder.level = 0.8
        #expect(InterviewViewState.announcements(from: noticed, to: louder).isEmpty, "le même avis est annoncé à chaque niveau")
        #expect(InterviewViewState.announcements(from: noticed, to: plain).isEmpty, "un avis effacé ne s'annonce pas")
        #expect(InterviewViewState.announcements(from: plain, to: noticed) == ["Rien n'a été compris."], "l'avis revenu n'est pas redit")
        // Un autre avis : annoncé ; avec un titre qui change en même temps : le titre d'abord.
        let other = state(.listening, notice: "Autre avis.")
        #expect(InterviewViewState.announcements(from: noticed, to: other) == ["Autre avis."])
        let both = state(.thinking, notice: "Autre avis.")
        #expect(InterviewViewState.announcements(from: noticed, to: both) == ["Réflexion…", "Autre avis."])
    }

    // MARK: La vue elle-même

    /// Hauteur du panneau entier pour cet état, à sa largeur de 520 points.
    private func panelHeight(_ state: InterviewViewState) -> CGFloat {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setInterview(state)
        let view = PanelView(model: model, permissions: PermissionsModel(probe: GrantedProbe()), openSettings: {}, quit: {})
        return NSHostingView(rootView: view).fittingSize.height
    }

    private func words(_ count: Int) -> String { Array(repeating: "précision", count: count).joined(separator: " ") }

    /// Le pire cas réaliste : une réplique et une réponse très longues, l'avis le plus long, la note de maintien, deux fournisseurs
    /// de 40 caractères dans la ligne de vie privée.
    private func worstCase(words count: Int) -> InterviewViewState {
        let forty = String(repeating: "x", count: Provider.shortNameLimit)
        var worst = InterviewViewState(maxQuestions: 12, privacy: InterviewText.privacy(provider: forty, voiceProvider: forty))
        worst.phase = .listening
        worst.question = 12
        worst.level = 1
        worst.questionText = words(count)
        worst.lastReply = words(count)
        worst.notice = InterviewText.failure(.engine("transcriptionNotPrepared"))
        worst.holdNote = true
        return worst
    }

    @Test("I6, M11 : au pire cas réaliste le panneau reste sous son budget de hauteur, quelle que soit la longueur des textes")
    func theWorstCasePanelStaysUnderTheHeightBudget() {
        let long = panelHeight(worstCase(words: 300))
        #expect(long <= InterviewView.panelHeightBudget, "\(long) pt pour un budget de \(InterviewView.panelHeightBudget) pt")
        // Des textes dix fois plus longs ne le font pas grandir : la zone défile, plafonnée.
        #expect(panelHeight(worstCase(words: 3_000)) == long)
        // La zone se plafonne vraiment : sans plafond, 300 mots feraient bien plus que la zone ; avec un texte court elle est plus basse.
        var short = worstCase(words: 300)
        short.questionText = "Pourquoi ?"
        short.lastReply = "Parce que."
        #expect(panelHeight(short) < long - 50, "un texte court prend autant de place qu'un texte long")
    }

    @Test("chaque état dessine sa propre vue, en clair comme en sombre")
    func everyPhaseDrawsItsOwnView() throws {
        for dark in [false, true] {
            var images: [Data] = []
            for phase in InterviewTextTests.phases {
                let view = InterviewView(state: state(phase, question: 2, questionText: "Une question ?", lastReply: "Une réponse."), conclude: {})
                images.append(try image(of: view.frame(width: 488).environment(\.colorScheme, dark ? .dark : .light)))
            }
            #expect(Set(images).count == images.count, "deux phases se dessinent de la même façon (sombre : \(dark))")
        }
    }

    private func panelImage(_ interview: InterviewViewState?, dictation: DictationViewState? = nil) throws -> Data {
        let model = PanelModel(lastModeID: "dictee-brute")
        if let dictation { model.setDictation(dictation) }
        model.setInterview(interview)
        let view = PanelView(model: model, permissions: PermissionsModel(probe: GrantedProbe()), openSettings: {}, quit: {})
        return try image(of: view)
    }

    @Test("I1 : le panneau montre la vue de l'entretien à la place de la dictée, quelle que soit la dictée")
    func thePanelShowsTheInterviewInsteadOfTheDictation() throws {
        let ready = try panelImage(nil)
        let listening = try panelImage(state(.listening, question: 1, questionText: "Une question ?"))
        let thinking = try panelImage(state(.thinking, question: 1, questionText: "Une question ?"))
        #expect(listening != ready)
        #expect(thinking != listening, "la vue de l'entretien ne suit pas la phase")
        #expect(try panelImage(nil) == ready, "retirer l'entretien ramène la dictée")
        // La dictée occupée (texte en direct, barres) ne se dessine pas sous l'entretien : l'image est la même qu'au repos.
        let busy = DictationViewState(stage: .recording, liveText: "un texte dit pendant l'entretien", levels: [0.3, 0.8, 0.5], elapsed: 4)
        let review = DictationViewState(stage: .review, lastTranscript: "Un texte à relire.", draft: "Un texte à relire.")
        for dictation in [busy, review] {
            #expect(try panelImage(state(.listening, question: 1, questionText: "Une question ?"), dictation: dictation) == listening,
                    "la dictée \(dictation.stage) est dessinée avec l'entretien")
        }
        // Sans entretien, ces mêmes dictées se dessinent : le test voit bien une différence quand elle existe.
        #expect(try panelImage(nil, dictation: busy) != ready)
    }

    private func image(of view: some View) throws -> Data {
        let host = NSHostingView(rootView: view.padding(8))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

/// Des permissions toutes accordées, pour que la ligne des permissions n'apparaisse pas.
private struct GrantedProbe: PermissionsProbe {
    func microphone() -> PermissionState { .granted }
    func accessibility() -> PermissionState { .granted }
    func requestMicrophone() async -> Bool { true }
    func promptAccessibility() {}
}
