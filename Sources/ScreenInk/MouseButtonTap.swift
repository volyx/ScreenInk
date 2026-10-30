import AppKit
import ScreenInkCore

/// Catches bound mouse buttons system-wide and hides them from other apps, so a side button
/// doesn't also navigate a browser. An active event tap needs Accessibility (PLAN.md §6).
@MainActor
final class MouseButtonTap {
    var map: MouseButtonMap
    private let onPress: (ToolKind) -> Void
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// Returns nil when the system refuses the tap. Call `stop()` before releasing it.
    init?(map: MouseButtonMap, onPress: @escaping (ToolKind) -> Void) {
        self.map = map
        self.onPress = onPress
        let mask = CGEventMask(1) << CGEventType.otherMouseDown.rawValue | CGEventMask(1) << CGEventType.otherMouseUp.rawValue
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                    // The tap's source is on the main run loop, so this runs on the main thread.
                    let consumed = MainActor.assumeIsolated {
                        Unmanaged<MouseButtonTap>.fromOpaque(refcon).takeUnretainedValue()
                            .handle(type, button: button)
                    }
                    return consumed ? nil : Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    /// Returns whether to hide the event. Both the press and the release are hidden,
    /// so no app ever sees a release without its press.
    private func handle(_ type: CGEventType, button: Int) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .otherMouseDown:
            guard let tool = map.tool(forButton: button) else { return false }
            onPress(tool)
            return true
        case .otherMouseUp:
            return map.tool(forButton: button) != nil
        default:
            return false
        }
    }
}

/// Turns side-button drawing on and off, and waits for the Accessibility permission it needs.
/// Off by default, so nothing prompts at first launch (PLAN.md §6).
@MainActor
final class SideButtonsController {
    private let toolState: ToolState
    private let screens: ScreensController
    private var tap: MouseButtonTap?
    private var retryTimer: Timer?

    init(toolState: ToolState, screens: ScreensController) {
        self.toolState = toolState
        self.screens = screens
        // Follows the config file too, which never prompts: the menu is the one place that does.
        toolState.observe { [weak self] in self?.update() }
        update()
    }

    var isEnabled: Bool { toolState.sideButtonsEnabled }

    /// Enabled, but the tap can't run until Accessibility is granted.
    var isWaitingForPermission: Bool { isEnabled && tap == nil }

    /// Toggled from the menu, the one place that may prompt.
    func setEnabled(_ enabled: Bool) {
        if enabled, !AXIsProcessTrusted() {
            guard explainPermission() else { return }
            // The literal key: the kAX… global isn't concurrency-safe under Swift 6.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        toolState.sideButtonsEnabled = enabled
    }

    private func update() {
        toolState.sideButtonsEnabled ? start() : stop()
        tap?.map = toolState.mouseButtons
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func explainPermission() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow ScreenInk to use your mouse's side buttons?"
        alert.informativeText = """
            The upper side button starts the pen and the lower one starts the rectangle. Drag to draw, \
            and click to erase everything and stop.

            macOS requires the Accessibility permission for this, so that the buttons don't also go Back or \
            Forward in the app underneath. While this is on, they won't navigate in any app. ScreenInk \
            only watches those two buttons.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func start() {
        guard tap == nil else { return }
        // Check first: a tap can be created without permission and then see nothing.
        if AXIsProcessTrusted() {
            tap = MouseButtonTap(map: toolState.mouseButtons) { [weak screens] tool in
                screens?.quickDraw(with: tool)
            }
        }
        if tap != nil {
            retryTimer?.invalidate()
            retryTimer = nil
        } else if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
        }
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        tap?.stop()
        tap = nil
    }
}
