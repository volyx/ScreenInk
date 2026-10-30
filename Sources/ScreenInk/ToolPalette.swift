import AppKit
import ScreenInkCore

/// Floating palette: tools, colors, width, undo/redo, clear, close.
///
/// A non-activating panel that never becomes key, so clicking it leaves keyboard focus on
/// the canvas (and the presenter's app keeps the menu bar). It can be dragged by its
/// background and remembers where it was left.
@MainActor
final class ToolPalette: NSObject {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onClear: (() -> Void)?
    var onClose: (() -> Void)?

    private let toolState: ToolState
    private let panel: NSPanel
    private var toolButtons: [ToolKind: NSButton] = [:]
    private var swatchButtons: [NSButton] = []
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 32, target: nil, action: nil)

    private static let symbols: [ToolKind: String] = [
        .pen: "pencil.tip", .highlighter: "highlighter", .line: "line.diagonal", .arrow: "arrow.up.right",
        .rectangle: "rectangle", .ellipse: "circle", .text: "textformat", .badge: "1.circle",
        .eraser: "eraser", .select: "cursorarrow",
    ]

    init(toolState: ToolState) {
        self.toolState = toolState
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 92, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = makeContent()
        panel.setContentSize(panel.contentView!.fittingSize)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove), name: NSWindow.didMoveNotification, object: panel)
        toolState.observe { [weak self] in self?.refresh() }
        refresh()
    }

    func show(on screen: NSScreen) {
        panel.setFrameOrigin(savedOrigin(fitting: panel.frame.size) ?? defaultOrigin(on: screen))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// The palette drawn off-screen (README screenshots).
    func renderImage() -> NSBitmapImageRep? {
        guard let view = panel.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let tools = grid(
            ToolKind.allCases.map { kind -> NSView in
                let button = iconButton(Self.symbols[kind] ?? "questionmark", action: #selector(selectTool(_:)))
                button.tag = ToolKind.allCases.firstIndex(of: kind)!
                toolButtons[kind] = button
                return button
            }, columns: 2)

        let swatches = grid(
            RGBA.palette.indices.map { index -> NSView in
                let button = NSButton(image: NSImage(), target: self, action: #selector(selectColor(_:)))
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.tag = index
                button.toolTip = "Color \(index + 1)"
                button.widthAnchor.constraint(equalToConstant: 22).isActive = true
                button.heightAnchor.constraint(equalToConstant: 22).isActive = true
                swatchButtons.append(button)
                return button
            }, columns: 3)

        widthSlider.target = self
        widthSlider.action = #selector(widthChanged(_:))
        widthSlider.controlSize = .small
        widthSlider.toolTip = "Width ([ and ])"
        widthSlider.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let actions = grid(
            [
                iconButton("arrow.uturn.backward", action: #selector(undo), toolTip: "Undo (⌘Z)"),
                iconButton("arrow.uturn.forward", action: #selector(redo), toolTip: "Redo (⇧⌘Z)"),
                iconButton("trash", action: #selector(clear), toolTip: "Clear All (C)"),
                iconButton("xmark", action: #selector(close), toolTip: "Stop Drawing (Esc)"),
            ], columns: 2)

        let stack = NSStackView(views: [tools, separator(), swatches, widthSlider, separator(), actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    private func grid(_ views: [NSView], columns: Int) -> NSGridView {
        let rows = stride(from: 0, to: views.count, by: columns).map { start in
            Array(views[start..<min(start + columns, views.count)])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        return grid
    }

    private func iconButton(_ symbol: String, action: Selector, toolTip: String? = nil) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return box
    }

    private func swatchImage(_ color: RGBA, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let fill = NSColor(cgColor: color.cgColor) ?? .black
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            // Light colors get a hairline so white stays visible on a light palette.
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).stroke()
            if selected {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            }
            return true
        }
    }

    private func refresh() {
        for (kind, button) in toolButtons {
            let selected = kind == toolState.tool
            button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : nil
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            let key = toolState.shortcuts.key(for: .tool(kind)).map { " (\($0.uppercased()))" } ?? ""
            button.toolTip = kind.title + key
        }
        for (index, button) in swatchButtons.enumerated() {
            button.image = swatchImage(RGBA.palette[index], selected: index == toolState.colorIndex)
        }
        widthSlider.doubleValue = toolState.width
    }

    // MARK: Position

    private func savedOrigin(fitting size: NSSize) -> NSPoint? {
        guard let origin = toolState.paletteOrigin else { return nil }
        let frame = NSRect(origin: origin, size: size)
        // Ignore a position on a display that's no longer attached.
        return NSScreen.screens.contains { $0.visibleFrame.contains(frame) } ? origin : nil
    }

    private func defaultOrigin(on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: visible.minX + 16, y: visible.midY - panel.frame.height / 2)
    }

    @objc private func panelDidMove() {
        toolState.paletteOrigin = panel.frame.origin
    }

    // MARK: Actions

    @objc private func selectTool(_ sender: NSButton) {
        toolState.tool = ToolKind.allCases[sender.tag]
    }

    @objc private func selectColor(_ sender: NSButton) {
        toolState.colorIndex = sender.tag
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        toolState.width = sender.doubleValue.rounded()
    }

    @objc private func undo() { onUndo?() }
    @objc private func redo() { onRedo?() }
    @objc private func clear() { onClear?() }
    @objc private func close() { onClose?() }
}
