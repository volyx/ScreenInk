import AppKit
import Carbon.HIToolbox
import ScreenInkCore

/// The drawing surface for one screen. Layers, bottom to top: the dimming veil, committed annotations,
/// transient overlay (previews, selection), the live stroke, and a text editor when typing.
/// Routes pointer input to the current tool and handles single-key shortcuts.
final class CanvasView: NSView, NSTextViewDelegate {
    let document: Document
    let toolState: ToolState
    /// Asked to hide the overlay (Esc with nothing selected).
    var onDeactivateRequest: (() -> Void)?
    /// Set during a quick-draw session: called for a click without a drag while a drag-drawn tool is current.
    var onPlainClick: (() -> Void)?

    let dimView: DimView
    let annotationsView: AnnotationsView
    let overlayView: OverlayLayerView
    let liveView: LiveStrokeView

    private var tool: CanvasTool
    private var toolKind: ToolKind
    private var textEditor: (view: NSTextView, editing: Annotation?, fontSize: CGFloat, color: RGBA)?

    var selection: Set<UUID> = [] {
        didSet { updateSelectionIndicator() }
    }
    private var dragOffset: CGVector?
    private var clickDetector: ClickDetector?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, document: Document, toolState: ToolState) {
        self.document = document
        self.toolState = toolState
        toolKind = toolState.tool
        tool = makeTool(toolState.tool)
        let bounds = NSRect(origin: .zero, size: frame.size)
        dimView = DimView(frame: bounds)
        annotationsView = AnnotationsView(frame: bounds)
        overlayView = OverlayLayerView(frame: bounds)
        liveView = LiveStrokeView(frame: bounds)
        super.init(frame: frame)
        wantsLayer = true
        for view in [dimView, annotationsView, overlayView, liveView] as [NSView] {
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        document.onChange = { [weak self] in self?.documentDidChange() }
        dimView.setLevel(toolState.dimLevel, animated: false)
        toolState.observe { [weak self] in self?.toolStateDidChange() }
        documentDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func documentDidChange() {
        annotationsView.sync(with: document.annotations, scale: backingScale)
        let ids = Set(document.annotations.map(\.id))
        if !selection.isSubset(of: ids) {
            selection.formIntersection(ids)
        } else {
            updateSelectionIndicator()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        annotationsView.sync(with: document.annotations, scale: backingScale)
    }

    // MARK: Tools

    private func toolStateDidChange() {
        dimView.setLevel(toolState.dimLevel, animated: true)
        guard toolState.tool != toolKind else { return }
        tool.cancel(in: self)
        clickDetector = nil
        endTextEditing()
        toolKind = toolState.tool
        tool = makeTool(toolKind)
        if toolKind != .select { selection = [] }
        refreshCursor()
    }

    /// Shows the tool's cursor if the pointer is over this canvas.
    func refreshCursor() {
        if window?.isVisible == true, let window,
            bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        {
            tool.cursor.set()
        }
    }

    /// Inserts a finished annotation and schedules its auto-fade if enabled.
    func commit(_ annotation: Annotation) {
        document.insert(annotation)
        guard let seconds = toolState.autoFadeSeconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.document.annotations.contains(where: { $0.id == annotation.id }) else { return }
            self.annotationsView.fadeOut(id: annotation.id, duration: 0.4) { [weak self] in
                self?.document.remove(ids: [annotation.id])
            }
        }
    }

    /// Fades everything out, then clears (one undo step).
    func clearWithFade() {
        endTextEditing()
        guard !document.annotations.isEmpty else { return }
        annotationsView.fadeOutAll(duration: 0.25) { [weak self] in self?.document.removeAll() }
    }

    /// Ends any gesture in progress, e.g. when the overlay hides.
    func cancelInteraction() {
        tool.cancel(in: self)
        endTextEditing()
        selection = []
    }

    // MARK: Selection

    func setDragOffset(_ offset: CGVector?) {
        dragOffset = offset
        annotationsView.dragOffset = offset.map { (selection, $0) }
        updateSelectionIndicator()
    }

    private func updateSelectionIndicator() {
        let offset = dragOffset ?? .zero
        let rects = document.annotations.filter { selection.contains($0.id) }.map {
            $0.bounds.offsetBy(dx: offset.dx, dy: offset.dy)
        }
        overlayView.showSelection(rects)
    }

    // MARK: Text editing

    var isEditingText: Bool { textEditor != nil }
    var editingTextView: NSTextView? { textEditor?.view }

    func beginTextEditing(at origin: CGPoint) {
        startEditor(origin: origin, string: "", editing: nil, fontSize: toolState.fontSize, color: toolState.color)
    }

    func beginTextEditing(editing annotation: Annotation) {
        guard case let .text(origin, string, fontSize) = annotation.geometry else { return }
        selection = []
        annotationsView.hiddenIDs.insert(annotation.id)
        startEditor(
            origin: origin, string: string, editing: annotation, fontSize: fontSize, color: annotation.style.color)
    }

    private func startEditor(origin: CGPoint, string: String, editing: Annotation?, fontSize: CGFloat, color: RGBA) {
        endTextEditing()
        let lineHeight = TextOutline.lineHeight(fontSize: fontSize)
        let textView = NSTextView(frame: NSRect(x: origin.x, y: origin.y, width: 4, height: lineHeight))
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = NSColor(cgColor: color.cgColor)
        textView.insertionPointColor = NSColor(cgColor: color.cgColor) ?? .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 4, height: lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = string
        textView.delegate = self
        textView.sizeToFit()
        addSubview(textView)
        textEditor = (textView, editing, fontSize, color)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    /// Commits the text being edited (or deletes it when emptied).
    func endTextEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil
        let string = editor.view.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = editor.view.frame.origin
        editor.view.delegate = nil
        editor.view.removeFromSuperview()
        if window?.firstResponder == nil || window?.firstResponder === editor.view {
            window?.makeFirstResponder(self)
        }

        if let existing = editor.editing {
            annotationsView.hiddenIDs.remove(existing.id)
            if string.isEmpty {
                document.remove(ids: [existing.id])
            } else {
                document.update(ids: [existing.id], actionName: "Edit Text") {
                    $0.geometry = .text(origin: origin, string: string, fontSize: editor.fontSize)
                }
            }
        } else if !string.isEmpty {
            commit(
                Annotation(
                    geometry: .text(origin: origin, string: string, fontSize: editor.fontSize),
                    style: Style(color: editor.color, width: toolState.width)))
        }
    }

    func textDidChange(_ notification: Notification) {
        textEditor?.view.sizeToFit()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Esc finishes typing.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isEditingText, toolKind != .text {
            endTextEditing()
        }
        window?.makeFirstResponder(isEditingText ? textEditor?.view : self)
        pointerDown(input(from: event))
    }

    override func mouseDragged(with event: NSEvent) {
        pointerDragged(input(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        pointerUp(input(from: event))
    }

    private func pointerDown(_ input: PointerInput) {
        clickDetector = onPlainClick != nil && toolKind.isDragDrawn ? ClickDetector(start: input.point) : nil
        tool.mouseDown(input, in: self)
    }

    private func pointerDragged(_ input: PointerInput) {
        clickDetector?.move(to: input.point)
        tool.mouseDragged(input, in: self)
    }

    private func pointerUp(_ input: PointerInput) {
        clickDetector?.move(to: input.point)
        let isPlainClick = clickDetector?.isClick == true
        clickDetector = nil
        if isPlainClick {
            tool.cancel(in: self)
            onPlainClick?()
        } else {
            tool.mouseUp(input, in: self)
        }
    }

    private func input(from event: NSEvent) -> PointerInput {
        let modifiers = event.modifierFlags
        let pressure = Double(event.pressure)
        return PointerInput(
            point: convert(event.locationInWindow, from: nil), pressure: pressure > 0 ? pressure : 1,
            shift: modifiers.contains(.shift), option: modifiers.contains(.option), clickCount: event.clickCount)
    }

    /// Drives a whole gesture through the current tool (self-test).
    func simulateGesture(_ points: [CGPoint], shift: Bool = false, option: Bool = false, clickCount: Int = 1) {
        guard let first = points.first, let last = points.last else { return }
        func sample(_ point: CGPoint) -> PointerInput {
            PointerInput(point: point, shift: shift, option: option, clickCount: clickCount)
        }
        pointerDown(sample(first))
        for point in points.dropFirst().dropLast() { pointerDragged(sample(point)) }
        if points.count > 1 { pointerDragged(sample(last)) }
        pointerUp(sample(last))
    }

    /// Mid-gesture access for the self-test.
    var currentTool: CanvasTool { tool }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        tool.cursor.set()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch Int(event.keyCode) {
        case kVK_Escape:
            if !selection.isEmpty {
                selection = []
            } else {
                onDeactivateRequest?()
            }
            return
        case kVK_Delete, kVK_ForwardDelete:
            document.remove(ids: selection)
            return
        default:
            break
        }
        guard modifiers.isEmpty, let characters = event.charactersIgnoringModifiers,
            let action = toolState.shortcuts.action(for: characters)
        else {
            super.keyDown(with: event)
            return
        }
        perform(action)
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case let .tool(kind):
            toolState.tool = kind
        case let .color(index):
            guard RGBA.palette.indices.contains(index) else { return }
            if selection.isEmpty {
                toolState.colorIndex = index
            } else {
                document.update(ids: selection, actionName: "Change Color") { $0.style.color = RGBA.palette[index] }
            }
        case .thinner:
            toolState.width = WidthSteps.next(after: toolState.width, thicker: false)
        case .thicker:
            toolState.width = WidthSteps.next(after: toolState.width, thicker: true)
        case .clear:
            clearWithFade()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While typing, ⌘Z etc. belong to the text view.
        guard !isEditingText else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch (Int(event.keyCode), modifiers) {
        case (kVK_ANSI_Z, [.command]):
            document.undo()
        case (kVK_ANSI_Z, [.command, .shift]):
            document.redo()
        case (kVK_ANSI_A, [.command]):
            toolState.tool = .select
            selection = Set(document.annotations.map(\.id))
        case (kVK_ANSI_RightBracket, [.command]):
            document.bringToFront(ids: selection)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
