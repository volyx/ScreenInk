import Foundation
import ScreenInkCore

/// Current tool, color, width and other options, shared by every screen and the palette.
/// Persisted through `onSettingsChange` to the config file.
@MainActor
final class ToolState {
    var tool: ToolKind {
        didSet { changed() }
    }
    var colorIndex: Int {
        didSet { changed() }
    }
    var width: Double {
        didSet { changed() }
    }
    /// When set, each new annotation fades out and is removed after this many seconds.
    var autoFadeSeconds: Double? {
        didSet { changed() }
    }
    /// How much the screen behind the ink is darkened while drawing, as a fraction of black (0 = off).
    var dimLevel: Double {
        didSet { changed() }
    }
    /// The global hotkey that starts and stops drawing.
    var hotKey: HotKeySpec {
        didSet { changed() }
    }
    /// Whether the mouse's side buttons start drawing. Needs Accessibility, so it's off until asked for.
    var sideButtonsEnabled: Bool {
        didSet { changed() }
    }
    var shortcuts: ShortcutMap {
        didSet { changed() }
    }
    var mouseButtons: MouseButtonMap {
        didSet { changed() }
    }
    /// Where the palette was left. Only saved: nothing on screen depends on it until the palette next opens.
    var paletteOrigin: CGPoint? {
        didSet { if !isApplying { onSettingsChange?(settings) } }
    }
    /// Called with the new settings after a change made in the app.
    var onSettingsChange: ((Settings) -> Void)?

    private var observers: [() -> Void] = []
    private var isApplying = false

    init(settings: Settings = Settings()) {
        tool = settings.tool
        colorIndex = settings.colorIndex
        width = settings.width
        autoFadeSeconds = settings.autoFadeSeconds
        dimLevel = settings.dimLevel
        hotKey = settings.hotKey
        sideButtonsEnabled = settings.sideButtonsEnabled
        shortcuts = settings.shortcuts
        mouseButtons = settings.mouseButtons
        paletteOrigin = settings.paletteOrigin
    }

    var settings: Settings {
        var settings = Settings()
        settings.tool = tool
        settings.colorIndex = colorIndex
        settings.width = width
        settings.autoFadeSeconds = autoFadeSeconds
        settings.dimLevel = dimLevel
        settings.hotKey = hotKey
        settings.sideButtonsEnabled = sideButtonsEnabled
        settings.shortcuts = shortcuts
        settings.mouseButtons = mouseButtons
        settings.paletteOrigin = paletteOrigin
        return settings
    }

    /// Takes on settings read from the config file, updating observers once and saving nothing.
    func apply(_ settings: Settings) {
        isApplying = true
        tool = settings.tool
        colorIndex = settings.colorIndex
        width = settings.width
        autoFadeSeconds = settings.autoFadeSeconds
        dimLevel = settings.dimLevel
        hotKey = settings.hotKey
        sideButtonsEnabled = settings.sideButtonsEnabled
        shortcuts = settings.shortcuts
        mouseButtons = settings.mouseButtons
        paletteOrigin = settings.paletteOrigin
        isApplying = false
        observers.forEach { $0() }
    }

    var color: RGBA { RGBA.palette[colorIndex] }

    /// Text size follows the width so one control sizes everything.
    var fontSize: CGFloat { CGFloat(max(14, width * 5)) }

    var badgeRadius: CGFloat { CGFloat(max(13, width * 2.5 + 8)) }

    func style(for tool: ToolKind) -> Style {
        switch tool {
        case .highlighter:
            Style(color: color, width: width * 4, opacity: 0.4, blend: .multiply)
        default:
            Style(color: color, width: width)
        }
    }

    func observe(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    private func changed() {
        guard !isApplying else { return }
        onSettingsChange?(settings)
        observers.forEach { $0() }
    }
}
