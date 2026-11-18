import SwiftUI

/// Onglet Entretien : le nombre de questions, le gabarit du prompt final, la vie privée, puis les réglages avancés de
/// l'interruption dans un groupe repliable. Toute la logique est dans `InterviewSettingsModel`, dont viennent aussi les bornes, les
/// pas et les phrases : cette vue n'en recopie aucun.
public struct InterviewPane: View {
    @Bindable var model: InterviewSettingsModel
    /// Le groupe « Réglages avancés » est-il ouvert ? Replié par défaut ; `advancedExpanded` ne sert qu'à rendre l'état ouvert.
    @State private var advancedExpanded: Bool

    public init(model: InterviewSettingsModel, advancedExpanded: Bool = false) {
        self.model = model
        _advancedExpanded = State(initialValue: advancedExpanded)
    }

    /// Le champ du gabarit est borné : un gabarit plus long défile dans le champ.
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
                    Stepper(value: $model.maxQuestions, in: model.maxQuestionsRange) {
                        LabeledContent(InterviewSettingsModel.maxQuestionsTitle) {
                            Text("\(model.maxQuestions)").monospacedDigit()
                        }
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
    }

    @ViewBuilder
    private var advanced: some View {
        Stepper(value: $model.turnSilence, in: model.turnSilenceRange, step: model.turnSilenceStep) {
            LabeledContent(InterviewSettingsModel.turnSilenceTitle) {
                Text(model.turnSilenceLabel).monospacedDigit()
            }
        }
        note(model.effectiveSilenceText)
        Stepper(
            value: $model.interruptMinDuration, in: model.interruptMinDurationRange, step: model.interruptMinDurationStep
        ) {
            LabeledContent(InterviewSettingsModel.interruptMinDurationTitle) {
                Text(model.interruptMinDurationLabel).monospacedDigit()
            }
        }
        Stepper(value: $model.interruptLevel, in: model.interruptLevelRange, step: model.interruptLevelStep) {
            LabeledContent(InterviewSettingsModel.interruptLevelTitle) {
                Text(model.interruptLevelLabel).monospacedDigit()
            }
        }
        note(InterviewSettingsModel.interruptNote)
        HStack {
            Spacer()
            Button(InterviewSettingsModel.restoreAdvancedTitle) { model.restoreAdvanced() }
                .controlSize(.small)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
