import SwiftUI

/// Onglet Entretien : le nombre de questions, le gabarit du prompt final, la vie privée, puis les réglages avancés de
/// l'interruption dans un groupe repliable. Toute la logique est dans `InterviewSettingsModel`, dont viennent aussi les bornes, les
/// pas et les phrases : cette vue n'en recopie aucun.
public struct InterviewPane: View {
    @Bindable var model: InterviewSettingsModel
    /// Le groupe « Réglages avancés » est-il ouvert ? Replié par défaut ; `advancedExpanded` ne sert qu'à rendre l'état ouvert.
    @State private var advancedExpanded: Bool
    /// Le champ du gabarit a la main : quand il la perd, le gabarit tapé est enregistré.
    @FocusState private var templateFocused: Bool

    public init(model: InterviewSettingsModel, advancedExpanded: Bool = false) {
        self.model = model
        _advancedExpanded = State(initialValue: advancedExpanded)
    }

    /// Le champ du gabarit est borné : un gabarit plus long défile dans le champ. Hauteurs en points : choix non mesuré, vu en image
    /// (le gabarit d'origine, cinq lignes, y tient entier).
    static let templateMinHeight: CGFloat = 90
    static let templateMaxHeight: CGFloat = 130

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
            Form {
                Section {
                    note(InterviewSettingsModel.header)
                    note(InterviewSettingsModel.modelsNote)
                    Label(model.privacyText, systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let holdNote = model.holdNote {
                        note(holdNote)
                    }
                }
                Section {
                    stepperRow(InterviewSettingsModel.maxQuestionsTitle, value: "\(model.maxQuestions)") {
                        Stepper(
                            InterviewSettingsModel.maxQuestionsTitle, value: $model.maxQuestions, in: model.maxQuestionsRange)
                    }
                    note(InterviewSettingsModel.maxQuestionsNote)
                } header: {
                    Text("Questions")
                }
                Section {
                    TextEditor(text: $model.template)
                        .font(.body)
                        .frame(minHeight: Self.templateMinHeight, maxHeight: Self.templateMaxHeight)
                        .accessibilityLabel(InterviewSettingsModel.templateTitle)
                        .focused($templateFocused)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    HStack(alignment: .firstTextBaseline) {
                        note(InterviewSettingsModel.templateNote)
                        Spacer(minLength: 8)
                        Button(InterviewSettingsModel.restoreTemplateTitle) { model.restoreTemplate() }
                            .controlSize(.small)
                            .disabled(model.isDefaultTemplate)
                    }
                } header: {
                    Text(InterviewSettingsModel.templateTitle)
                }
                Section {
                    DisclosureGroup(InterviewSettingsModel.advancedTitle, isExpanded: $advancedExpanded) {
                        advanced
                    }
                }
            }
            .formStyle(.grouped)
        }
        // Un réglage ajouté ailleurs pendant que la fenêtre était gardée s'y voit à chaque affichage de l'onglet.
        .onAppear { model.reload() }
        // Le champ perd la main, ou l'onglet disparaît : le gabarit tapé est enregistré (une seule écriture).
        .onChange(of: templateFocused) { if !templateFocused { model.commitTemplate() } }
        .onDisappear { model.commitTemplate() }
    }

    @ViewBuilder
    private var advanced: some View {
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

    /// Une ligne : le titre à gauche, la valeur puis les flèches à droite. Le titre reste celui que VoiceOver lit pour le contrôle,
    /// et la valeur est son état.
    private func stepperRow(_ title: String, value: String, @ViewBuilder stepper: () -> some View) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(value).monospacedDigit().foregroundStyle(.secondary)
                stepper().labelsHidden().accessibilityValue(value)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
