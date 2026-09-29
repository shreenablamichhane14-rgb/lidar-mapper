import Foundation
import simd

/// Prompt answers of the plan editor (docs/MODULES.md 3.37, rule "Prompts"): typed lengths go
/// through `PlanEditorPresentation.parseLength` with the action's range; a rejected text keeps the
/// sheet open with `promptError` set to `Copy.PlanEditor.invalidLength` or the range message.
extension PlanEditorModel {
    /// Text of a value, name or annotation prompt.
    func submit(_ prompt: PlanEditorPrompt, text: String) {
        promptError = nil
        switch prompt {
        case .wallLength(let id, _):
            guard let length = typedLength(text, range: PlanEditorOps.wallLengthRange) else { return }
            performFromPrompt(.setWallLength(id, length: length), shown: prompt, select: id)
        case .wallThickness(let id, _):
            guard let thickness = typedLength(text, range: PlanEditorOps.thicknessRange) else { return }
            performFromPrompt(.setWallThickness(id, thickness: thickness), shown: prompt, select: id)
        case .openingSize(let id, _, _):
            guard let width = typedLength(text, range: PlanEditorOps.openingWidthRange) else { return }
            performFromPrompt(.resizeOpening(id, width: width, height: nil), shown: prompt, select: id)
        case .renameRoom(let id, _):
            performFromPrompt(.renameRoom(id, name: text), shown: prompt, select: id)
        case .annotation(let kind, let at, let editing, _):
            submitAnnotation(kind: kind, at: at, editing: editing, text: text)
        case .category:
            close(prompt)
        case .resetConfirmation:
            close(prompt)
            do {
                try resetToScan()
            } catch {
                record("reset not made: \(error)")
            }
        }
    }

    /// Width and height of the opening size prompt (two fields); an empty height keeps both
    /// heights.
    func submitOpeningSize(_ id: ElementID, width widthText: String, height heightText: String) {
        promptError = nil
        guard let width = typedLength(widthText, range: PlanEditorOps.openingWidthRange) else { return }
        var height: Float?
        if !heightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let typed = typedLength(heightText, range: PlanEditorOps.openingHeightRange) else { return }
            height = typed
        }
        guard let shown = prompt else { return }
        performFromPrompt(.resizeOpening(id, width: width, height: height), shown: shown, select: id)
    }

    /// Add Symbol (or a changed symbol): the chosen symbol at `at`.
    func submitSymbol(_ symbol: String, at: Vec2) {
        var editing: ElementID?
        if case .annotation(_, _, let id, _)? = prompt { editing = id }
        prompt = nil
        promptError = nil
        let id = editing ?? ElementID()
        let existing = editing.flatMap { levelAnnotation($0) }
        let symbolAnnotation = PlanAnnotation(id: id, kind: .symbol, at: existing?.at ?? at, text: existing?.text ?? "",
                                              symbol: symbol)
        finishAnnotation(symbolAnnotation)
    }

    /// Change Category of a fixture.
    func submitCategory(_ category: ObjectCategory, for fixture: ElementID) {
        prompt = nil
        promptError = nil
        attempt(.recategorizeFixture(fixture, category), thenSelect: fixture)
    }

    /// Text or note: a new annotation, or the edited one with new text (an empty text adds
    /// nothing and leaves an edited one unchanged).
    private func submitAnnotation(kind: AnnotationKind, at: Vec2, editing: ElementID?, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = nil
        guard !trimmed.isEmpty else {
            if editing == nil { cancelTool() }
            return
        }
        if let editing, let existing = levelAnnotation(editing) {
            var changed = existing
            if existing.kind == .symbol {
                changed.symbol = trimmed
            } else {
                changed.text = trimmed
            }
            finishAnnotation(changed)
            return
        }
        let isSymbol = kind == .symbol
        finishAnnotation(PlanAnnotation(id: ElementID(), kind: kind, at: at, text: isSymbol ? "" : trimmed,
                                        symbol: isSymbol ? trimmed : nil))
    }

    /// Performs Add Text, Symbol or Note (or its change) and selects it.
    private func finishAnnotation(_ annotation: PlanAnnotation) {
        finishAdd(.setAnnotation(annotation), select: annotation.id)
    }

    /// The annotation with this id on the edited level.
    private func levelAnnotation(_ id: ElementID) -> PlanAnnotation? {
        committedLevel?.annotations.first { $0.id == id }
    }

    /// Performs a prompt's action while its sheet is still open: on success the sheet closes and
    /// `id` is selected; a refusal stays in the sheet as `promptError` instead of an alert (an
    /// alert cannot show while the sheet is dismissing).
    private func performFromPrompt(_ action: PlanEditAction, shown: PlanEditorPrompt, select id: ElementID) {
        do {
            try perform(action)
            close(shown)
            selection = id
        } catch {
            promptError = message ?? PlanEditorPresentation.message(for: .notFound, prefs: prefs)
            message = nil
        }
    }

    /// Closes a prompt if it is still the shown one.
    private func close(_ shown: PlanEditorPrompt) {
        if prompt == shown { prompt = nil }
    }

    /// A typed length inside `range`, or nil with `promptError` set to why it was rejected.
    private func typedLength(_ text: String, range: ClosedRange<Float>) -> Float? {
        if let value = PlanEditorPresentation.parseLength(text, prefs: prefs, range: range) { return value }
        promptError = PlanEditorPresentation.lengthProblem(text, prefs: prefs, range: range)
        return nil
    }

    /// The starting text of a length field for a prompt value.
    func lengthText(_ meters: Float) -> String {
        PlanEditorPresentation.lengthText(meters, prefs: prefs)
    }

    // MARK: - Presentation state (bound by the screen as `$model.<name>`)

    /// The prompt shown as a sheet: every prompt but the reset confirmation (an alert). Setting
    /// nil (the sheet was swiped away) closes the prompt and clears its error.
    var sheetPrompt: PlanEditorPrompt? {
        get {
            guard let shown = prompt, shown != .resetConfirmation else { return nil }
            return shown
        }
        set {
            guard newValue == nil, let shown = prompt, shown != .resetConfirmation else { return }
            prompt = nil
            promptError = nil
        }
    }

    /// True while the Reset to Scan confirmation shows; setting false closes it.
    var isResetConfirmationShown: Bool {
        get { prompt == .resetConfirmation }
        set {
            if !newValue, prompt == .resetConfirmation { prompt = nil }
        }
    }

    /// True while a refusal or write failure message shows; setting false clears it.
    var isMessageShown: Bool {
        get { message != nil }
        set {
            if !newValue { message = nil }
        }
    }
}
