import SwiftUI

/// Onglet Entretien. La fenêtre de réglages a une hauteur fixe (`SettingsView.windowSize`, avec sa barre d'onglets) : ce qui se règle passe avant ce qui
/// se lit une fois. De haut en bas : une phrase d'introduction, le nombre de questions et, sous lui, la ligne « Voix » (avec
/// l'onglet Voix), le gabarit du prompt final (champ de hauteur
/// bornée), les réglages avancés de l'interruption (groupe repliable, replié), puis, en bas, un bloc de notes (le reste de l'en-tête,
/// les modèles, la vie privée, la note de maintien). Toute la logique est dans `InterviewSettingsModel`, dont viennent aussi les
/// bornes, les pas et les phrases : cette vue n'en recopie aucun.
public struct InterviewPane: View {
    @Bindable var model: InterviewSettingsModel
    /// Le groupe « Réglages avancés » est-il ouvert ? Replié par défaut ; `advancedExpanded` ne sert qu'à rendre l'état ouvert.
    @State private var advancedExpanded: Bool
    /// Le champ du gabarit a la main : quand il la perd, le gabarit tapé est enregistré.
    @FocusState private var templateFocused: Bool
    /// Mesure : reçoit le bas de l'intitulé « Réglages avancés », en points depuis le haut du volet (défilement à zéro). Sert au test
    /// qui exige que l'intitulé tienne dans la hauteur de la fenêtre ; `nil` en production.
    private let onAdvancedHeadingBottom: (@MainActor (CGFloat) -> Void)?
    /// « Choisir la voix… » : mène à l'onglet Voix ; `nil` : pas de ligne « Voix » (pas d'onglet Voix).
    private let chooseVoice: (@MainActor () -> Void)?
    /// Mesure : reçoit le cadre de la ligne « Voix », puis celui de la phrase d'introduction, en points dans le repère du volet
    /// (défilement à zéro) ; `nil` en production.
    private let onVoiceRowFrame: (@MainActor (CGRect) -> Void)?
    private let onIntroductionFrame: (@MainActor (CGRect) -> Void)?

    public init(
        model: InterviewSettingsModel, advancedExpanded: Bool = false, chooseVoice: (@MainActor () -> Void)? = nil,
        onAdvancedHeadingBottom: (@MainActor (CGFloat) -> Void)? = nil,
        onVoiceRowFrame: (@MainActor (CGRect) -> Void)? = nil,
        onIntroductionFrame: (@MainActor (CGRect) -> Void)? = nil
    ) {
        self.model = model
        _advancedExpanded = State(initialValue: advancedExpanded)
        self.chooseVoice = chooseVoice
        self.onAdvancedHeadingBottom = onAdvancedHeadingBottom
        self.onVoiceRowFrame = onVoiceRowFrame
        self.onIntroductionFrame = onIntroductionFrame
    }

    /// Hauteur du champ du gabarit, en points : environ cinq lignes du texte courant. Choix non mesuré, vu en image. Un gabarit plus
    /// long défile dans le champ.
    static let templateFieldHeight: CGFloat = 88
    /// Largeur utile de l'introduction et du formulaire, en points : celle où les cartes du formulaire groupé gardent leur marge
    /// de 20 points et l'introduction tombe sur leurs lignes (mesuré par `theIntroductionLinesUpWithTheFormRows`). Choix vu en
    /// image à 860 points de fenêtre.
    static let contentMaxWidth: CGFloat = 740
    static let coordinateSpaceName = "interviewPane"

    public var body: some View {
        VStack(spacing: 0) {
            // Le refus est une rangée au-dessus du formulaire, comme dans les autres onglets : il reste visible quand il défile.
            if let message = model.message {
                ModesMessageLine(text: message)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            // L'introduction et le formulaire dans une colonne de largeur bornée, centrée : le formulaire groupé plafonne déjà ses
            // cartes, et l'introduction s'aligne ainsi sur ses lignes au lieu de rester au bord de la fenêtre (vu à 860 points).
            VStack(spacing: 0) {
                // L'introduction est une phrase au-dessus du formulaire, hors carte : une carte de plus coûterait une quarantaine de points
                // à une fenêtre de hauteur fixe.
                note(InterviewSettingsModel.introduction)
                    .background(introductionProbe)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Form {
                    Section {
                        // La note du nombre de questions est le sous-titre de sa ligne (pas une rangée à part) : la ligne « Voix » tient
                        // alors sous elle sans pousser l'intitulé « Réglages avancés » hors de la hauteur visible (mesuré, tâche 4, D).
                        stepperRow(
                            InterviewSettingsModel.maxQuestionsTitle, caption: InterviewSettingsModel.maxQuestionsNote,
                            value: "\(model.maxQuestions)"
                        ) {
                            Stepper(
                                InterviewSettingsModel.maxQuestionsTitle, value: $model.maxQuestions, in: model.maxQuestionsRange)
                        }
                        // La voix de Supervox se choisit dans l'onglet Voix : une ligne du premier groupe, visible sans défiler.
                        if let chooseVoice {
                            LabeledContent(VoicesText.voiceRowTitle) {
                                HStack(spacing: 12) {
                                    Text(VoicesText.voiceRowCaption).foregroundStyle(.secondary)
                                    Button(VoicesText.chooseVoiceTitle, action: chooseVoice)
                                }
                            }
                            .background(voiceRowProbe)
                        }
                    }
                    Section {
                        TextEditor(text: $model.template)
                            .font(.body)
                            .frame(height: Self.templateFieldHeight)
                            .accessibilityLabel(InterviewSettingsModel.templateTitle)
                            .focused($templateFocused)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        note(InterviewSettingsModel.templateNote)
                    } header: {
                        // Le bouton est sur la ligne du titre : il ne prend pas une rangée de plus (hauteur de fenêtre fixe).
                        HStack {
                            Text(InterviewSettingsModel.templateTitle)
                            Spacer(minLength: 8)
                            Button(InterviewSettingsModel.restoreTemplateTitle) { model.restoreTemplate() }
                                .controlSize(.small)
                                .disabled(model.isDefaultTemplate)
                        }
                    }
                    Section {
                        DisclosureGroup(isExpanded: $advancedExpanded) {
                            advanced
                        } label: {
                            Text(InterviewSettingsModel.advancedTitle)
                                .background(headingProbe)
                        }
                    }
                    Section {
                        note(InterviewSettingsModel.introductionRest)
                        note(InterviewSettingsModel.modelsNote)
                        Label(model.privacyText, systemImage: "lock.shield")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let holdNote = model.holdNote {
                            note(holdNote)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxWidth: Self.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(AdvancedHeadingBottomKey.self) { bottom in
            if let bottom { onAdvancedHeadingBottom?(bottom) }
        }
        .onPreferenceChange(VoiceRowFrameKey.self) { frame in
            if let frame { onVoiceRowFrame?(frame) }
        }
        .onPreferenceChange(IntroductionFrameKey.self) { frame in
            if let frame { onIntroductionFrame?(frame) }
        }
        // Un réglage ajouté ailleurs pendant que la fenêtre était gardée s'y voit à chaque affichage de l'onglet.
        .onAppear { model.reload() }
        // Le champ perd la main, ou l'onglet disparaît : le gabarit tapé est enregistré (une seule écriture).
        .onChange(of: templateFocused) { if !templateFocused { model.commitTemplate() } }
        .onDisappear { model.commitTemplate() }
    }

    /// Rapporte le bas de l'intitulé du groupe avancé (seulement quand quelqu'un mesure).
    private var headingProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: AdvancedHeadingBottomKey.self,
                value: onAdvancedHeadingBottom == nil
                    ? nil : geometry.frame(in: .named(Self.coordinateSpaceName)).maxY)
        }
    }

    /// Rapporte le cadre de la ligne « Voix » (seulement quand quelqu'un mesure).
    private var voiceRowProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: VoiceRowFrameKey.self,
                value: onVoiceRowFrame == nil ? nil : geometry.frame(in: .named(Self.coordinateSpaceName)))
        }
    }

    /// Rapporte le cadre de la phrase d'introduction (seulement quand quelqu'un mesure).
    private var introductionProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: IntroductionFrameKey.self,
                value: onIntroductionFrame == nil ? nil : geometry.frame(in: .named(Self.coordinateSpaceName)))
        }
    }

    /// Les trois réglages avancés et leurs notes, dans UNE colonne : un seul retrait pour les lignes et pour les notes (le groupe
    /// retire les textes seuls plus que les lignes de réglage).
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepperRow(InterviewSettingsModel.turnSilenceTitle, value: model.turnSilenceLabel) {
                Stepper(
                    InterviewSettingsModel.turnSilenceTitle, value: $model.turnSilence, in: model.turnSilenceRange,
                    step: model.turnSilenceStep)
            }
            note(model.effectiveSilenceText)
            stepperRow(InterviewSettingsModel.interruptMinDurationTitle, value: model.interruptMinDurationLabel) {
                Stepper(
                    InterviewSettingsModel.interruptMinDurationTitle, value: $model.interruptMinDuration,
                    in: model.interruptMinDurationRange, step: model.interruptMinDurationStep)
            }
            stepperRow(InterviewSettingsModel.interruptLevelTitle, value: model.interruptLevelLabel) {
                Stepper(
                    InterviewSettingsModel.interruptLevelTitle, value: $model.interruptLevel, in: model.interruptLevelRange,
                    step: model.interruptLevelStep)
            }
            note(InterviewSettingsModel.interruptNote)
            HStack {
                Spacer()
                Button(InterviewSettingsModel.restoreAdvancedTitle) { model.restoreAdvanced() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Une ligne : le titre à gauche, la valeur puis les flèches à droite. Le titre reste celui que VoiceOver lit pour le contrôle,
    /// et la valeur est son état.
    /// `caption` : une phrase sous le titre, dans la même ligne (sous-titre de `LabeledContent`).
    private func stepperRow(
        _ title: String, caption: String? = nil, value: String, @ViewBuilder stepper: () -> some View
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(value).monospacedDigit().foregroundStyle(.secondary)
                stepper().labelsHidden().accessibilityValue(value)
            }
        } label: {
            Text(title)
            if let caption { Text(caption) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Le bas de l'intitulé « Réglages avancés » dans le repère du volet ; `nil` quand personne ne mesure.
private struct AdvancedHeadingBottomKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// Le cadre de la ligne « Voix » dans le repère du volet ; `nil` quand personne ne mesure.
private struct VoiceRowFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// Le cadre de la phrase d'introduction dans le repère du volet ; `nil` quand personne ne mesure.
private struct IntroductionFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
