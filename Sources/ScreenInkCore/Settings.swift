import CoreGraphics
import Foundation

/// A global hotkey as written in the config file, e.g. `ctrl+option+cmd+a`.
public struct HotKeySpec: Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Sendable {
        case ctrl, option, shift, cmd

        var symbol: String {
            switch self {
            case .ctrl: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .cmd: "⌘"
            }
        }
    }

    public var key: String
    public var modifiers: Set<Modifier>

    public static let `default` = HotKeySpec(key: "a", modifiers: [.ctrl, .option, .cmd])

    private static let modifierNames: [String: Modifier] = [
        "ctrl": .ctrl, "control": .ctrl, "option": .option, "opt": .option, "alt": .option, "shift": .shift,
        "cmd": .cmd, "command": .cmd,
    ]

    /// macOS virtual key codes, which are fixed by the hardware layout.
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(parsing string: String, line: Int? = nil) throws {
        var modifiers: Set<Modifier> = []
        var key: String?
        for part in string.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let name = part.trimmingCharacters(in: .whitespaces)
            if let modifier = Self.modifierNames[name] {
                modifiers.insert(modifier)
            } else if Self.keyCodes[name] != nil, key == nil {
                key = name
            } else {
                throw ConfigError(
                    line: line, "“\(string)” isn't a hotkey. Use modifiers and one letter, digit, space or f1–f12, like ctrl+option+cmd+a.")
            }
        }
        guard let key else {
            throw ConfigError(line: line, "The hotkey “\(string)” has no key, only modifiers.")
        }
        // A bare letter would stop that letter being typed anywhere on the system.
        if modifiers.isEmpty, !(key.hasPrefix("f") && key.count > 1) {
            throw ConfigError(line: line, "The hotkey “\(string)” needs a modifier such as ctrl or cmd.")
        }
        self.init(key: key, modifiers: modifiers)
    }

    public var keyCode: UInt32 { Self.keyCodes[key] ?? 0 }

    /// The form written to the config file.
    public var description: String {
        (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+")
    }

    /// The form shown in the menu, e.g. ⌃⌥⌘A.
    public var displayString: String {
        Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + key.capitalized
    }
}

/// Every user-visible option, as stored in `~/.ScreenInk/config.yml`.
public struct Settings: Equatable, Sendable {
    public static let widthRange = 1.0...32.0
    public static let dimRange = 0.0...0.8
    public static let fadeRange = 0.0...86400.0
    /// 0 and 1 are the left and right buttons, which have to keep working.
    public static let mouseButtonRange = 2...31

    public var tool: ToolKind = .pen
    /// Index into `RGBA.palette`.
    public var colorIndex = 0
    public var width = 4.0
    public var autoFadeSeconds: Double?
    public var dimLevel = 0.0
    public var hotKey = HotKeySpec.default
    public var sideButtonsEnabled = false
    public var mouseButtons = MouseButtonMap.defaults
    public var shortcuts = ShortcutMap.defaults
    public var paletteOrigin: CGPoint?

    public init() {}

    /// Reads a config file. Missing options keep their defaults; anything unknown or
    /// out of range is an error, so a typo can't be silently ignored.
    public init(yaml: String) throws {
        self.init()
        var paletteX: (value: Double, line: Int)?
        var paletteY: (value: Double, line: Int)?
        for entry in try SimpleYAML.parse(yaml) {
            let node = entry.node
            switch entry.key {
            case "tool":
                tool = try Self.tool(node)
            case "color":
                let name = try Self.scalar(node, entry.key).lowercased()
                guard let index = RGBA.paletteNames.firstIndex(of: name) else {
                    throw ConfigError(
                        line: node.line, "“\(name)” isn't a color. Use one of: \(RGBA.paletteNames.joined(separator: ", ")).")
                }
                colorIndex = index
            case "width":
                width = try Self.number(node, entry.key, in: Self.widthRange)
            case "auto_fade_seconds":
                let seconds = try Self.number(node, entry.key, in: Self.fadeRange)
                autoFadeSeconds = seconds > 0 ? seconds : nil
            case "dim_level":
                dimLevel = try Self.number(node, entry.key, in: Self.dimRange)
            case "hotkey":
                hotKey = try HotKeySpec(parsing: Self.scalar(node, entry.key), line: node.line)
            case "side_buttons":
                sideButtonsEnabled = try Self.bool(node, entry.key)
            case "mouse_buttons":
                mouseButtons = try Self.mouseButtons(node)
            case "shortcuts":
                shortcuts = try Self.shortcuts(node)
            case "palette_x":
                paletteX = (try Self.number(node, entry.key, in: -1_000_000...1_000_000), node.line)
            case "palette_y":
                paletteY = (try Self.number(node, entry.key, in: -1_000_000...1_000_000), node.line)
            default:
                throw ConfigError(line: node.line, "Unknown option “\(entry.key)”.")
            }
        }
        switch (paletteX, paletteY) {
        case let (x?, y?):
            paletteOrigin = CGPoint(x: x.value, y: y.value)
        case let (x?, nil):
            throw ConfigError(line: x.line, "palette_x needs palette_y as well.")
        case let (nil, y?):
            throw ConfigError(line: y.line, "palette_y needs palette_x as well.")
        case (nil, nil):
            break
        }
    }

    /// The whole file, with a comment explaining each option.
    public var yaml: String {
        let tools = ToolKind.allCases.map(\.rawValue).joined(separator: ", ")
        let colors = RGBA.paletteNames.joined(separator: ", ")
        let modifiers = HotKeySpec.Modifier.allCases.map(\.rawValue).joined(separator: ", ")
        var lines = [
            "# ScreenInk settings. Changes apply as soon as you save.",
            "# Options you leave out use their defaults. If there's a mistake, ScreenInk names the line",
            "# and leaves this file alone until it's fixed.",
            "# ScreenInk rewrites this file when you change a setting in the app, which drops any comments you added.",
            "",
            "# The current tool.",
            "# Options: \(tools)",
            "tool: \(tool.rawValue)",
            "",
            "# The current color.",
            "# Options: \(colors)",
            "color: \(RGBA.paletteNames[colorIndex])",
            "",
            "# Line width in points.",
            "# Options: any number from \(Self.number(Self.widthRange.lowerBound)) to \(Self.number(Self.widthRange.upperBound))",
            "width: \(Self.number(width))",
            "",
            "# Fade each drawing out after this many seconds.",
            "# Options: 0 to never fade, or any number of seconds up to \(Self.number(Self.fadeRange.upperBound))",
            "auto_fade_seconds: \(Self.number(autoFadeSeconds ?? 0))",
            "",
            "# How much to darken the screen while drawing.",
            "# Options: any number from \(Self.number(Self.dimRange.lowerBound)) (off) to \(Self.number(Self.dimRange.upperBound)) (darkest)",
            "dim_level: \(Self.number(dimLevel))",
            "",
            "# The global hotkey that starts and stops drawing.",
            "# Format: modifiers and one key joined with +, like ctrl+option+cmd+a or shift+f5",
            "# Modifiers: \(modifiers)",
            "# Keys: a-z, 0-9, space, f1-f12 (f1-f12 can be used alone; the others need a modifier)",
            "hotkey: \(hotKey)",
            "",
            "# Start drawing from the mouse's side buttons. Needs the Accessibility permission.",
            "# Options: true, false",
            "side_buttons: \(sideButtonsEnabled)",
            "",
            "# Which tool each extra mouse button starts. Delete a line to unbind that button.",
            "# Buttons: \(Self.mouseButtonRange.lowerBound) to \(Self.mouseButtonRange.upperBound) (on an MX Master 3S, 4 is the upper side button and 3 the lower)",
            "# Tools: \(tools)",
            "mouse_buttons:",
        ]
        lines += mouseButtons.bindings.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value.rawValue)" }
        lines += [
            "",
            "# What each key does while drawing. Delete a line to unbind that key.",
            "# Keys: any single character, in quotes",
            "# Tools: \(tools)",
            "# Colors: \(colors)",
            "# Other actions: thinner, thicker, clear",
            "shortcuts:",
        ]
        lines += shortcuts.bindings.sorted { $0.key < $1.key }.map {
            "  \(Self.quoted($0.key)): \(Self.name(of: $0.value))"
        }
        lines += [
            "",
            "# Where the tool palette opens, in screen points from the bottom-left corner of the main display.",
            "# Options: any numbers, set together. Remove both to use the default position.",
        ]
        // Shown commented out when unset, so the option can still be found.
        let palettePrefix = paletteOrigin == nil ? "# " : ""
        lines += [
            "\(palettePrefix)palette_x: \(Self.number(paletteOrigin?.x ?? 16))",
            "\(palettePrefix)palette_y: \(Self.number(paletteOrigin?.y ?? 300))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Reading values

    private static func scalar(_ node: SimpleYAML.Node, _ key: String) throws -> String {
        guard case let .scalar(value) = node.value else {
            throw ConfigError(line: node.line, "“\(key)” needs a value.")
        }
        return value
    }

    private static func entries(_ node: SimpleYAML.Node, _ key: String) throws -> [SimpleYAML.Entry] {
        guard case let .map(entries) = node.value else {
            throw ConfigError(line: node.line, "“\(key)” needs an indented list of “key: value” lines.")
        }
        return entries
    }

    private static func number(_ node: SimpleYAML.Node, _ key: String, in range: ClosedRange<Double>) throws -> Double {
        let text = try scalar(node, key)
        guard let value = Double(text), range.contains(value) else {
            throw ConfigError(line: node.line, "“\(key)” must be a number from \(number(range.lowerBound)) to \(number(range.upperBound)), not “\(text)”.")
        }
        return value
    }

    private static func bool(_ node: SimpleYAML.Node, _ key: String) throws -> Bool {
        let text = try scalar(node, key)
        switch text.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: throw ConfigError(line: node.line, "“\(key)” must be true or false, not “\(text)”.")
        }
    }

    private static func tool(_ node: SimpleYAML.Node) throws -> ToolKind {
        let text = try scalar(node, "tool")
        guard let tool = ToolKind(rawValue: text.lowercased()) else {
            throw ConfigError(
                line: node.line, "“\(text)” isn't a tool. Use one of: \(ToolKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return tool
    }

    private static func mouseButtons(_ node: SimpleYAML.Node) throws -> MouseButtonMap {
        var bindings: [Int: ToolKind] = [:]
        for entry in try entries(node, "mouse_buttons") {
            guard let button = Int(entry.key), mouseButtonRange.contains(button) else {
                throw ConfigError(
                    line: entry.node.line,
                    "“\(entry.key)” isn't an extra mouse button. Use a number from \(mouseButtonRange.lowerBound) to \(mouseButtonRange.upperBound).")
            }
            bindings[button] = try tool(entry.node)
        }
        return MouseButtonMap(bindings: bindings)
    }

    private static func shortcuts(_ node: SimpleYAML.Node) throws -> ShortcutMap {
        var bindings: [String: ShortcutAction] = [:]
        for entry in try entries(node, "shortcuts") {
            guard entry.key.count == 1 else {
                throw ConfigError(line: entry.node.line, "“\(entry.key)” isn't a single key.")
            }
            let key = entry.key.lowercased()
            guard bindings[key] == nil else {
                throw ConfigError(line: entry.node.line, "“\(key)” is bound more than once.")
            }
            let name = try scalar(entry.node, entry.key)
            guard let action = action(named: name.lowercased()) else {
                throw ConfigError(line: entry.node.line, "“\(name)” isn't an action. Use a tool, a color, thinner, thicker or clear.")
            }
            bindings[key] = action
        }
        return ShortcutMap(bindings: bindings)
    }

    private static func action(named name: String) -> ShortcutAction? {
        if let tool = ToolKind(rawValue: name) { return .tool(tool) }
        if let index = RGBA.paletteNames.firstIndex(of: name) { return .color(index) }
        switch name {
        case "thinner": return .thinner
        case "thicker": return .thicker
        case "clear": return .clear
        default: return nil
        }
    }

    // MARK: Writing values

    private static func name(of action: ShortcutAction) -> String {
        switch action {
        case let .tool(kind): kind.rawValue
        case let .color(index): RGBA.paletteNames[index]
        case .thinner: "thinner"
        case .thicker: "thicker"
        case .clear: "clear"
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func number(_ value: CGFloat) -> String {
        number(Double(value))
    }

    /// Keys are always quoted: `[` needs it, and other YAML readers take a bare `n` for false.
    private static func quoted(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
