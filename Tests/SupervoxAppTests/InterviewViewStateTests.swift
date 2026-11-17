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
        #expect(titles == InterviewTextTests.phases.map(InterviewText.title))
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

    @Test("la question et la réplique montrées sont bornées, la fin gardée, la limite est réelle")
    func theShownTextsAreBoundedAndKeepTheirEnd() throws {
        let long = Array(repeating: "mot", count: 2_000).joined(separator: " ") + " fin"
        let question = state(questionText: long).shownQuestion
        #expect(question.count <= InterviewText.questionLimit && question.hasSuffix("fin") && question.hasPrefix("…"))
        let reply = try #require(state(lastReply: long).shownReply)
        #expect(reply.count <= DictationText.transcriptLimit && reply.hasSuffix("fin"))
        let fits = "Quelle est la durée du projet ?"
        #expect(state(questionText: fits).shownQuestion == fits)
    }

    // MARK: Règle 4 : Conclure

    @Test("règle 4 : « Conclure » est grisé en préparation et en conclusion, actif ailleurs")
    func concludeIsDisabledOnlyWhilePreparingAndConcluding() {
        for phase in InterviewTextTests.phases {
            #expect(state(phase).canConclude == (phase != .preparing && phase != .concluding), "\(phase)")
        }
    }

    private func concludeImage(enabled: Bool) throws -> Data {
        try image(of: ConcludeButton(enabled: enabled, action: {}).frame(width: 200).environment(\.controlActiveState, .key))
    }

    @Test("règle 4 : le bouton grisé ne se dessine pas comme le bouton actif")
    func theDisabledButtonLooksDisabled() throws {
        let on = try concludeImage(enabled: true)
        #expect(try concludeImage(enabled: true) == on, "le rendu n'est pas reproductible")
        #expect(try concludeImage(enabled: false) != on)
    }

    @Test("règle 3 : les pastilles verrouillées ne se dessinent pas comme les pastilles actives")
    func lockedChipsLookDisabled() throws {
        func chips(locked: Bool) throws -> Data {
            try image(of: ModeChips(modes: ModeChip.fixed, selectedID: "prompt", locked: locked, select: { _ in }).frame(width: 488))
        }
        #expect(try chips(locked: false) == chips(locked: false), "le rendu n'est pas reproductible")
        #expect(try chips(locked: true) != chips(locked: false))
    }

    // MARK: Règle 5 : l'orbe

    @Test("règle 5 : l'orbe porte le titre de l'état comme libellé et n'est pas un élément interactif")
    func theOrbCarriesTheTitleAndIsNotInteractive() {
        for phase in InterviewTextTests.phases {
            let spec = OrbAccessibility(phase: phase)
            #expect(spec.label == InterviewText.title(phase), "\(phase)")
            #expect(!spec.traits.contains(.isButton) && !spec.traits.contains(.isLink) && !spec.traits.contains(.isToggle))
        }
    }

    @Test("règle 5 : l'orbe suit le niveau du micro, borné, NaN lu comme le silence")
    func theOrbFollowsTheLevelBoundedAndNaNIsSilence() {
        let silent = OrbAppearance(level: 0, phase: .listening, reduceMotion: false)
        let loud = OrbAppearance(level: 1, phase: .listening, reduceMotion: false)
        let middle = OrbAppearance(level: 0.5, phase: .listening, reduceMotion: false)
        #expect(silent.scale == 1)
        #expect(loud.scale > middle.scale && middle.scale > silent.scale)
        #expect(OrbAppearance(level: 7, phase: .listening, reduceMotion: false) == loud)
        #expect(OrbAppearance(level: -3, phase: .listening, reduceMotion: false) == silent)
        #expect(OrbAppearance(level: .nan, phase: .listening, reduceMotion: false) == silent)
        #expect(OrbAppearance(level: .infinity, phase: .listening, reduceMotion: false) == loud)
    }

    @Test("règle 5 : avec « Réduire les animations » l'orbe reste fixe, seule l'opacité suit le niveau")
    func withReducedMotionTheOrbIsFixedAndOnlyItsOpacityFollowsTheLevel() {
        let silent = OrbAppearance(level: 0, phase: .listening, reduceMotion: true)
        let middle = OrbAppearance(level: 0.5, phase: .listening, reduceMotion: true)
        let loud = OrbAppearance(level: 1, phase: .listening, reduceMotion: true)
        #expect(silent.scale == 1 && middle.scale == 1 && loud.scale == 1)
        #expect(loud.opacity > middle.opacity && middle.opacity > silent.opacity)
        #expect(silent.opacity > 0, "l'orbe ne disparaît jamais")
        #expect(OrbAppearance(level: .nan, phase: .listening, reduceMotion: true) == silent)
        #expect(loud.opacity <= 1)
    }

    @Test("une phase d'attente éteint l'orbe : même niveau, moins d'opacité qu'à l'écoute")
    func aWaitingPhaseDimsTheOrb() {
        for reduce in [false, true] {
            let live = OrbAppearance(level: 0.6, phase: .listening, reduceMotion: reduce)
            #expect(OrbAppearance(level: 0.6, phase: .speaking, reduceMotion: reduce) == live)
            for phase in [InterviewPhase.preparing, .thinking, .concluding] {
                #expect(OrbAppearance(level: 0.6, phase: phase, reduceMotion: reduce).opacity < live.opacity, "\(phase)")
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
        let host = NSHostingView(rootView: InterviewOrb(level: level, phase: phase, reduceMotion: reduceMotion))
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

    @Test("règle 5 : dessiné, l'orbe grandit avec le niveau ; avec « Réduire les animations » sa silhouette ne bouge pas")
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

    @Test("l'orbe, au niveau le plus fort, n'est coupée par aucun bord de son cadre")
    func theLoudestOrbIsNotClippedByItsFrame() throws {
        for phase in [InterviewPhase.listening, .speaking] {
            let loud = try orb(level: 1, phase: phase, reduceMotion: false)
            #expect(loud.box.minX > 0 && loud.box.minY > 0, "\(loud.box) dans \(loud.size)")
            #expect(loud.box.maxX < loud.size.width && loud.box.maxY < loud.size.height, "\(loud.box) dans \(loud.size)")
        }
    }

    // MARK: Règle 5 : l'annonce VoiceOver

    @Test("règle 5 : le titre change, l'annonce est le nouveau titre ; le même titre ne s'annonce pas deux fois")
    func aNewTitleIsAnnouncedAndTheSameTitleIsNot() {
        #expect(InterviewViewState.announcement(from: nil, to: state(.preparing)) == "Préparation de l'entretien…")
        #expect(InterviewViewState.announcement(from: state(.preparing), to: state(.listening)) == "À vous")
        #expect(InterviewViewState.announcement(from: state(.listening), to: state(.thinking)) == "Réflexion…")
        // Le niveau, la question, les textes changent sans cesse : aucun ne change le titre.
        let before = state(.listening, question: 1, level: 0.1)
        let after = state(.listening, question: 2, questionText: "Autre ?", lastReply: "Oui.", level: 0.9, notice: "Avis.")
        #expect(InterviewViewState.announcement(from: before, to: after) == nil)
        #expect(InterviewViewState.announcement(from: state(.speaking), to: nil) == nil)
        #expect(InterviewViewState.announcement(from: nil, to: nil) == nil)
    }

    // MARK: La vue elle-même

    /// Hauteur de la vue pour cet état, à la largeur du panneau.
    private func height(of state: InterviewViewState) -> CGFloat {
        let host = NSHostingView(rootView: InterviewView(state: state, conclude: {}).frame(width: 488))
        return host.fittingSize.height
    }

    @Test("un texte démesuré ne fait pas grandir la vue : question et réplique sont bornées")
    func anEnormousTextDoesNotGrowTheView() {
        let words = Array(repeating: "précision", count: 1_000).joined(separator: " ")
        let big = state(.listening, question: 2, questionText: words, lastReply: words)
        let bigger = state(.listening, question: 2, questionText: words + " " + words, lastReply: words + " " + words)
        #expect(height(of: big) == height(of: bigger))
        let short = state(.listening, question: 2, questionText: "Pourquoi ?", lastReply: "Parce que.")
        #expect(height(of: big) > height(of: short), "le texte long prend plus de place que le court")
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

    private func panelImage(_ interview: InterviewViewState?) throws -> Data {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setInterview(interview)
        let view = PanelView(model: model, permissions: PermissionsModel(probe: GrantedProbe()), openSettings: {}, quit: {})
        return try image(of: view)
    }

    @Test("le panneau montre la vue de l'entretien à la place de la dictée tant qu'un entretien est posé")
    func thePanelShowsTheInterviewInsteadOfTheDictation() throws {
        let ready = try panelImage(nil)
        let listening = try panelImage(state(.listening, question: 1, questionText: "Une question ?"))
        let thinking = try panelImage(state(.thinking, question: 1, questionText: "Une question ?"))
        #expect(listening != ready)
        #expect(thinking != listening, "la vue de l'entretien ne suit pas la phase")
        #expect(try panelImage(nil) == ready, "retirer l'entretien ramène la dictée")
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
