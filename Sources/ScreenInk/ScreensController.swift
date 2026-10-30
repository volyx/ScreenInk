import AppKit
import ScreenInkCore

/// Owns one overlay panel per display, the document for each display, and the palette.
///
/// Documents are keyed by display ID and outlive their panels, so unplugging and
/// replugging a monitor (or any screen reconfiguration) keeps its drawing.
@MainActor
final class ScreensController {
    private struct Overlay {
        let panel: OverlayPanel
        let canvas: CanvasView
    }

    let toolState: ToolState
    private(set) var isActive = false {
        didSet { onActiveChange?(isActive) }
    }
    var onActiveChange: ((Bool) -> Void)?

    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var documents: [CGDirectDisplayID: Document] = [:]
    private let palette: ToolPalette
    private var screenObserver: NSObjectProtocol?
    /// Set during a quick-draw session: the tool to go back to when it ends.
    private var toolBeforeQuickDraw: ToolKind?

    init(toolState: ToolState) {
        self.toolState = toolState
        palette = ToolPalette(toolState: toolState)
        palette.onUndo = { [weak self] in self?.activeCanvas?.document.undo() }
        palette.onRedo = { [weak self] in self?.activeCanvas?.document.redo() }
        palette.onClear = { [weak self] in self?.clearAll() }
        palette.onClose = { [weak self] in self?.deactivate() }
        rebuildOverlays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        }
    }

    func toggle() {
        isActive ? deactivate() : activate()
    }

    /// Shows the overlays and makes the one under the pointer key, without activating the
    /// app, so the presenter's app keeps its menu bar and focus state.
    func activate(showsPalette: Bool = true) {
        for overlay in overlays.values {
            overlay.panel.ignoresMouseEvents = false
            overlay.panel.orderFrontRegardless()
        }
        if let overlay = overlayUnderPointer() {
            overlay.panel.makeKey()
            overlay.panel.makeFirstResponder(overlay.canvas)
            if showsPalette, let screen = overlay.panel.screen { palette.show(on: screen) }
        }
        isActive = true
    }

    func deactivate() {
        for overlay in overlays.values {
            overlay.canvas.cancelInteraction()
            overlay.panel.ignoresMouseEvents = true
            overlay.panel.orderOut(nil)
        }
        palette.hide()
        isActive = false
        if let tool = toolBeforeQuickDraw {
            toolBeforeQuickDraw = nil
            updatePlainClickHandlers()
            toolState.tool = tool
        }
    }

    /// A mouse side button: starts a quick-draw session, in which a plain click erases everything
    /// and stops. During a hotkey session it only switches tool, so a click there never wipes the drawing.
    func quickDraw(with tool: ToolKind) {
        if !isActive {
            toolBeforeQuickDraw = toolState.tool
            activate(showsPalette: false)
            updatePlainClickHandlers()
        }
        toolState.tool = tool
        activeCanvas?.refreshCursor()
    }

    private func clearAndDeactivate() {
        for document in documents.values { document.removeAll() }
        deactivate()
    }

    private func updatePlainClickHandlers() {
        let handler: (() -> Void)? = toolBeforeQuickDraw == nil ? nil : { [weak self] in self?.clearAndDeactivate() }
        for overlay in overlays.values { overlay.canvas.onPlainClick = handler }
    }

    func clearAll() {
        for overlay in overlays.values {
            if isActive {
                overlay.canvas.clearWithFade()
            } else {
                overlay.canvas.document.removeAll()
            }
        }
    }

    var hasAnnotations: Bool {
        documents.values.contains { !$0.annotations.isEmpty }
    }

    /// The canvas receiving keyboard input, or the one under the pointer.
    private var activeCanvas: CanvasView? {
        (overlays.values.first { $0.panel.isKeyWindow } ?? overlayUnderPointer())?.canvas
    }

    private func overlayUnderPointer() -> Overlay? {
        let pointer = NSEvent.mouseLocation
        return overlays.values.first { $0.panel.frame.contains(pointer) } ?? overlays.values.first
    }

    private func rebuildOverlays() {
        var current: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { current[id] = screen }
        }

        for (id, overlay) in overlays where current[id] == nil {
            overlay.canvas.cancelInteraction()
            overlay.panel.orderOut(nil)
            overlay.panel.close()
            overlays[id] = nil
        }

        for (id, screen) in current {
            if let overlay = overlays[id] {
                overlay.panel.setFrame(screen.frame, display: true)
                continue
            }
            let document = documents[id] ?? Document()
            documents[id] = document
            let panel = OverlayPanel(screen: screen)
            let canvas = CanvasView(
                frame: NSRect(origin: .zero, size: screen.frame.size), document: document, toolState: toolState)
            canvas.autoresizingMask = [.width, .height]
            canvas.onDeactivateRequest = { [weak self] in self?.deactivate() }
            panel.contentView = canvas
            overlays[id] = Overlay(panel: panel, canvas: canvas)
            if isActive {
                panel.ignoresMouseEvents = false
                panel.orderFrontRegardless()
            }
        }
        updatePlainClickHandlers()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
