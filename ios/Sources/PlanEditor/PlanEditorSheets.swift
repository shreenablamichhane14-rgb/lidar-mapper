import SwiftUI
import UIKit

/// The sheet of one prompt: typed values and names (`PlanEditorValueSheet`) or a choice list
/// (`PlanEditorChoiceSheet`: symbols and categories).
struct PlanEditorPromptSheet: View {
    /// The prompt shown.
    let prompt: PlanEditorPrompt
    /// The editing session that answers it.
    @ObservedObject var model: PlanEditorModel

    /// The value or choice sheet for the prompt.
    var body: some View {
        Group {
            switch prompt {
            case .category(let id, let current):
                PlanEditorChoiceSheet(title: Copy.ObjectMenu.changeCategory, model: model,
                                      choices: PlanEditorPromptSheet.categoryChoices(), selected: current.rawValue) { key in
                    guard let category = ObjectCategory(rawValue: key) else { return }
                    model.submitCategory(category, for: id)
                }
            case .annotation(.symbol, let at, let editing, let current):
                PlanEditorChoiceSheet(title: PlanEditorPromptSheet.symbolTitle(editing: editing), model: model,
                                      choices: PlanEditorPromptSheet.symbolChoices(), selected: current) { key in
                    model.submitSymbol(key, at: at)
                }
            default:
                PlanEditorValueSheet(prompt: prompt, model: model)
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Every object category by its display name.
    static func categoryChoices() -> [PlanEditorChoice] {
        ObjectCategory.allCases.map { category in
            PlanEditorChoice(key: category.rawValue, title: Copy.FloorPlan.categoryName(category))
        }
    }

    /// The Add Symbol choices.
    static func symbolChoices() -> [PlanEditorChoice] {
        PlanEditorPresentation.symbols.map { symbol in PlanEditorChoice(key: symbol, title: symbol) }
    }

    /// Title of the symbol sheet: Add Symbol, or Edit Text when changing one.
    static func symbolTitle(editing: ElementID?) -> String {
        editing == nil ? Copy.FloorPlan.addSymbol : Copy.PlanEditor.editText
    }
}

/// One entry of a choice list.
struct PlanEditorChoice: Identifiable, Equatable {
    /// Stable key (category raw value or the symbol text).
    let key: String
    /// Shown text.
    let title: String
    /// Identity for `ForEach`.
    var id: String { key }
}

/// A list of choices with a checkmark on the current one; a tap answers the prompt.
struct PlanEditorChoiceSheet: View {
    /// Sheet title.
    let title: String
    /// The editing session (Cancel clears its prompt).
    @ObservedObject var model: PlanEditorModel
    /// The choices in display order.
    let choices: [PlanEditorChoice]
    /// Key of the current choice.
    let selected: String
    /// Called with the chosen key.
    let onPick: (String) -> Void

    /// The choice list in a navigation stack with Cancel.
    var body: some View {
        NavigationStack {
            List(choices) { choice in
                Button {
                    onPick(choice.key)
                } label: {
                    HStack {
                        Text(choice.title)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if choice.key == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .accessibilityAddTraits(choice.key == selected ? .isSelected : [])
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Project.cancel) {
                        model.promptError = nil
                        model.prompt = nil
                    }
                }
            }
        }
    }
}

/// Typed values (wall length and thickness, opening width and height through `LengthParser`),
/// room names, and text or note annotations. A rejected value keeps the sheet open with the
/// model's `promptError`.
struct PlanEditorValueSheet: View {
    /// The prompt answered.
    let prompt: PlanEditorPrompt
    /// The editing session.
    @ObservedObject var model: PlanEditorModel
    /// The main field and, for an opening, the height field.
    @State private var text = ""
    @State private var secondText = ""
    /// Keyboard focus of the main field.
    @FocusState private var focused: Bool

    /// A sheet answering `prompt` through `model`.
    init(prompt: PlanEditorPrompt, model: PlanEditorModel) {
        self.prompt = prompt
        self._model = ObservedObject(wrappedValue: model)
    }

    /// The form with Cancel and Save.
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    fields
                } footer: {
                    if let error = model.promptError {
                        Text(error)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Project.cancel) {
                        model.promptError = nil
                        model.prompt = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Measure.save) { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            text = initialText
            secondText = initialSecondText
            focused = true
        }
    }

    /// The text fields of the prompt.
    @ViewBuilder private var fields: some View {
        switch prompt {
        case .openingSize:
            LabeledContent(Copy.Viewer.width) {
                lengthField(Copy.Viewer.width, text: $text)
                    .focused($focused)
            }
            LabeledContent(Copy.Viewer.height) {
                lengthField(Copy.Viewer.height, text: $secondText)
            }
        case .wallLength, .wallThickness:
            lengthField(title, text: $text)
                .focused($focused)
        case .annotation(.note, _, _, _):
            TextField(Copy.FloorPlan.notePlaceholder, text: $text, axis: .vertical)
                .lineLimit(2...6)
                .focused($focused)
        case .annotation:
            TextField(Copy.FloorPlan.textPlaceholder, text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { save() }
        case .renameRoom:
            TextField(Copy.House.nameRoomPlaceholder, text: $text)
                .textInputAutocapitalization(.words)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { save() }
        case .category, .resetConfirmation:
            EmptyView()
        }
    }

    /// A field for a typed length (feet and inches or metric).
    private func lengthField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .multilineTextAlignment(.trailing)
            .submitLabel(.done)
            .onSubmit { save() }
    }

    /// Sheet title for the prompt.
    private var title: String {
        switch prompt {
        case .wallLength: return Copy.FloorPlan.wallLength
        case .wallThickness: return Copy.FloorPlan.wallThickness
        case .openingSize: return PlanEditorPresentation.title(.resizeOpening, item: model.selectedItem)
        case .renameRoom: return Copy.FloorPlan.renameRoom
        case .annotation(let kind, _, let editing, _):
            if editing != nil { return Copy.PlanEditor.editText }
            switch kind {
            case .text: return Copy.FloorPlan.addText
            case .symbol: return Copy.FloorPlan.addSymbol
            case .note: return Copy.FloorPlan.addNote
            }
        case .category: return Copy.ObjectMenu.changeCategory
        case .resetConfirmation: return Copy.FloorPlan.resetToScan
        }
    }

    /// Starting text of the main field.
    private var initialText: String {
        switch prompt {
        case .wallLength(_, let current), .wallThickness(_, let current): return model.lengthText(current)
        case .openingSize(_, let width, _): return model.lengthText(width)
        case .renameRoom(_, let current): return current
        case .annotation(_, _, _, let current): return current
        case .category, .resetConfirmation: return ""
        }
    }

    /// Starting text of the height field (empty keeps both heights).
    private var initialSecondText: String {
        guard case .openingSize(_, _, let height?) = prompt else { return "" }
        return model.lengthText(height)
    }

    /// Sends the fields to the model; the model closes the sheet when the value is accepted.
    private func save() {
        switch prompt {
        case .openingSize(let id, _, _):
            model.submitOpeningSize(id, width: text, height: secondText)
        default:
            model.submit(prompt, text: text)
        }
    }
}
