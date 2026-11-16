import SwiftUI

/// La feuille d'un mode : nom, consigne, modèle, moteur, relecture, raccourci. Rien n'est écrit avant « Enregistrer », sauf le
/// raccourci (sa capture l'enregistre) ; « Revenir à la consigne d'origine » ne change que le brouillon, « Annuler » le défait.
///
/// La feuille a une taille bornée : une consigne de plusieurs milliers de caractères défile dans son champ, elle n'agrandit pas
/// la feuille hors de l'écran.
public struct ModeEditor: View {
    let model: ModesModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModeDraft
    private let height: CGFloat

    /// `draft` : ce que la feuille montre à l'ouverture (`nil` : le mode tel que les réglages le portent). Sert au rendu d'un état
    /// précis (consigne modifiée, raccourci refusé…).
    public init(model: ModesModel, id: String, draft: ModeDraft? = nil, height: CGFloat = ModeEditor.sheetHeight) {
        self.model = model
        self.height = height
        _draft = State(initialValue: draft ?? model.draft(for: id))
    }

    /// La feuille a une hauteur fixe, qui tient dans un écran de portable sous la fenêtre de réglages : le formulaire défile.
    /// `height` ne change que pour rendre toute la feuille en une image. Seul un bandeau d'erreur l'augmente (`bannerRoom`).
    public static let sheetHeight: CGFloat = 640
    /// La place que la feuille prend de plus tant qu'un bandeau d'erreur est affiché. Le bandeau est au-dessus du formulaire, dans
    /// une feuille dont la hauteur ne change pas avec le contenu du formulaire : sans cette place, il pousse la dernière phrase
    /// d'aide (« Le raccourci lance ce mode… ») sous la barre des boutons, coupée à mi-ligne. 60 points, avec les 35 de marge que
    /// la feuille la plus chargée (Prompt, consigne d'origine, modèle, raccourci) laisse sans bandeau, absorbent un bandeau de
    /// quatre lignes, le plus long que l'on sache produire (un refus suivi de la phrase du raccourci général non rétabli) ; vu en
    /// image. 640 + 60 = 700 : le budget que `theSheetHasABoundedHeight…` borne. Au-delà, le formulaire défile.
    public static let bannerRoom: CGFloat = 60
    /// Le champ de consigne est borné : une consigne plus longue défile dans le champ.
    static let instructionMinHeight: CGFloat = 80
    static let instructionMaxHeight: CGFloat = 120

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Le refus est une rangée au-dessus du formulaire, comme dans l'onglet : il reste visible quand le formulaire défile.
            if let message = model.message {
                ModesMessageLine(text: message)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            Form {
                Section {
                    TextField("Nom", text: $draft.name)
                }
                instructionSection
                if sendsText {
                    Section {
                        ModelPicker(
                            title: "Modèle utilisé", noneTitle: ModesModel.defaultModelTitle,
                            content: model.pickerContent(selected: draft.model), selection: draft.model,
                            onSelect: { draft.model = $0 })
                        ModelPickerNotes(content: model.pickerContent(selected: draft.model))
                        if let note = model.modelNote(for: draft) {
                            WarningLine(text: note)
                        }
                        if let privacy = model.privacyNote(for: draft) {
                            Label(privacy, systemImage: "lock.shield")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section {
                    Picker("Moteur de dictée", selection: $draft.engine) {
                        Text(ModesModel.noTranscriptionEngineTitle).tag(TranscriptionEngine?.none)
                        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                            Text(engine.title).tag(TranscriptionEngine?.some(engine))
                        }
                    }
                    Toggle(ModesModel.toggleTitle, isOn: $draft.reviews)
                        .disabled(AppSettings.alwaysReviewed.contains(draft.id))
                    if AppSettings.alwaysReviewed.contains(draft.id) {
                        Text(ModesModel.alwaysReviewedNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Raccourci du mode") {
                        HStack(spacing: 8) {
                            ModeHotKeyRecorder(model: model, id: draft.id)
                            Button("Retirer") { model.clearHotKey(for: draft.id) }
                                .disabled(model.hotKeyLabel(for: draft.id) == nil || model.recordingModeID != nil)
                        }
                    }
                } header: {
                    Text("Dictée")
                } footer: {
                    Text("Le raccourci lance ce mode de n'importe où. Échap annule la capture.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    if model.save(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520, height: height + (model.message == nil ? 0 : Self.bannerRoom))
        // Une capture ne survit pas à la feuille : les raccourcis reviennent. Un refus resté à l'écran n'a plus d'objet.
        .onDisappear { model.editorClosed() }
    }

    // MARK: - Consigne

    /// Le texte part au fournisseur : le mode a une consigne, qui n'est pas blanche.
    private var sendsText: Bool {
        draft.isInstructionEditable && !draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// La consigne d'origine du mode, s'il est de base.
    private var origin: String? { ModeDefaults.instruction(for: draft.id) }

    @ViewBuilder
    private var instructionSection: some View {
        Section {
            if draft.isInstructionEditable {
                TextEditor(text: $draft.instruction)
                    .font(.body)
                    .frame(minHeight: Self.instructionMinHeight, maxHeight: Self.instructionMaxHeight)
                    .accessibilityLabel("Consigne")
                    .overlay(alignment: .topLeading) {
                        if draft.instruction.isEmpty {
                            Text("Par exemple : « Mets ce texte en forme de courriel poli. »")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            } else {
                Text(ModesModel.lockedInstructionNote(for: draft.id))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Consigne")
        } footer: {
            if draft.isInstructionEditable {
                // Le bouton est sur la ligne de l'explication : il ne prend pas une rangée de plus dans une feuille de hauteur fixe.
                HStack(alignment: .firstTextBaseline) {
                    Text("Sans consigne, le texte est collé tel quel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let origin, draft.instruction != origin {
                        Button("Revenir à la consigne d'origine") { draft.resetInstructionToOrigin() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Le bouton qui capte la prochaine combinaison tapée pour ce mode. Toute la logique est dans `ModesModel`.
private struct ModeHotKeyRecorder: View {
    let model: ModesModel
    let id: String

    var body: some View {
        let isRecording = model.recordingModeID == id
        Button {
            isRecording ? model.cancelRecording() : model.startRecording(for: id)
        } label: {
            Text(isRecording ? "Tapez la combinaison…" : (model.hotKeyLabel(for: id) ?? "Aucun"))
                .font(isRecording ? .body : .body.monospaced())
                .frame(minWidth: 140)
        }
        .help(isRecording ? "Échap pour annuler" : "Cliquer pour choisir un raccourci")
    }
}
