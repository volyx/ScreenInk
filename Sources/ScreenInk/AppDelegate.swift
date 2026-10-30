import AppKit
import ScreenInkCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var screens: ScreensController?
    private var statusItem: StatusItemController?
    private var activateHotKey: HotKey?
    private var registeredHotKey: HotKeySpec?
    private var sideButtons: SideButtonsController?
    private var toolState: ToolState?
    private let config = ConfigFile()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = config.load(initial: .legacy(from: .standard))
        let toolState = ToolState(settings: settings)
        self.toolState = toolState
        let screens = ScreensController(toolState: toolState)
        self.screens = screens

        let sideButtons = SideButtonsController(toolState: toolState, screens: screens)
        self.sideButtons = sideButtons

        let statusItem = StatusItemController(
            screens: screens, toolState: toolState, sideButtons: sideButtons, config: config)
        self.statusItem = statusItem
        screens.onActiveChange = { [weak statusItem] active in statusItem?.updateIcon(active: active) }

        toolState.onSettingsChange = { [weak self] settings in self?.config.save(settings) }
        config.onExternalChange = { [weak toolState] settings in toolState?.apply(settings) }
        config.onProblem = { [weak self] problem in self?.showConfigProblem(problem) }
        toolState.observe { [weak self] in self?.updateHotKey() }

        updateHotKey()
        if let problem = config.problem { showConfigProblem(problem) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        config.flush()
    }

    /// Registers the hotkey at launch and whenever the config file changes it.
    private func updateHotKey() {
        guard let toolState, let screens, toolState.hotKey != registeredHotKey else { return }
        let spec = toolState.hotKey
        registeredHotKey = spec
        activateHotKey?.unregister()
        activateHotKey = HotKey(spec) { [weak screens] in screens?.toggle() }
        statusItem?.hotKeyDescription = activateHotKey == nil ? nil : spec.displayString
        if activateHotKey == nil {
            showAlert(
                "Shortcut \(spec.displayString) is already in use",
                "Another app has claimed it. Use the menu-bar icon to start drawing.")
        }
    }

    private func showConfigProblem(_ problem: String) {
        showAlert(
            "There's a problem in config.yml",
            "\(problem)\n\nScreenInk will keep its current settings and won't change the file until it's fixed.")
    }

    private func showAlert(_ message: String, _ information: String) {
        // Below the overlay's window level, a modal alert would block input with nothing visible.
        // The menu still shows config problems afterwards.
        guard screens?.isActive != true else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        NSApp.activate()
        alert.runModal()
    }
}
