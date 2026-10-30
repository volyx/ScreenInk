import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import ScreenInkCore

@Suite struct SimpleYAMLTests {
    private func scalar(_ entries: [SimpleYAML.Entry], _ key: String) -> String? {
        guard case let .scalar(value)? = entries.first(where: { $0.key == key })?.node.value else { return nil }
        return value
    }

    @Test func readsScalarsCommentsAndQuotes() throws {
        let entries = try SimpleYAML.parse(
            """
            ---
            # a comment
            plain: hello world   # trailing comment
            hash: a#b
            double: "x # y"
            single: 'it''s'
            escaped: "a\\"b\\\\c"
            "[": quoted key
            """)
        #expect(scalar(entries, "plain") == "hello world")
        #expect(scalar(entries, "hash") == "a#b")
        #expect(scalar(entries, "double") == "x # y")
        #expect(scalar(entries, "single") == "it's")
        #expect(scalar(entries, "escaped") == "a\"b\\c")
        #expect(scalar(entries, "[") == "quoted key")
    }

    @Test func readsNestedMaps() throws {
        let entries = try SimpleYAML.parse("outer:\n  a: 1\n\n  b: 2\nnext: 3\nempty:\n")
        guard case let .map(children)? = entries.first?.node.value else {
            Issue.record("outer isn't a map")
            return
        }
        #expect(children.map(\.key) == ["a", "b"])
        #expect(scalar(entries, "next") == "3")
        #expect(entries.last?.node.value == .map([]))
    }

    @Test func acceptsWindowsLineEndings() throws {
        #expect(try SimpleYAML.parse("a: 1\r\nb: 2\r\n").map(\.key) == ["a", "b"])
    }

    @Test(arguments: [
        ("a: 1\na: 2", 2), ("a: 1\n  b: 2", 2), ("\ta: 1", 1), ("just text", 1), ("a:1", 1), ("- item", 1),
        ("a: [1, 2]", 1), ("a: {b: 1}", 1), ("a: \"open", 1), ("a: \"x\" y", 1), ("a:\n    b: 1\n  c: 2", 3),
        ("  a: 1\nb: 2", 1),
    ])
    func rejectsWhatItDoesNotSupport(text: String, line: Int) {
        #expect {
            _ = try SimpleYAML.parse(text)
        } throws: { error in
            // The first indented line of an unindented file has nothing valid to attach to.
            (error as? ConfigError)?.line == line
        }
    }
}

@Suite struct SettingsTests {
    @Test func emptyFileMeansDefaults() throws {
        #expect(try Settings(yaml: "") == Settings())
        #expect(try Settings(yaml: "# nothing here\n") == Settings())
    }

    @Test func defaultsRoundTrip() throws {
        #expect(try Settings(yaml: Settings().yaml) == Settings())
    }

    @Test func everyOptionRoundTrips() throws {
        var settings = Settings()
        settings.tool = .arrow
        settings.colorIndex = 8
        settings.width = 2.5
        settings.autoFadeSeconds = 10
        settings.dimLevel = 0.35
        settings.hotKey = HotKeySpec(key: "f5", modifiers: [.shift])
        settings.sideButtonsEnabled = true
        settings.mouseButtons = MouseButtonMap(bindings: [5: .ellipse, 3: .pen])
        settings.shortcuts = ShortcutMap(bindings: ["[": .thinner, "\"": .clear, "\\": .color(2), "n": .tool(.badge)])
        settings.paletteOrigin = CGPoint(x: 1775, y: -20.5)
        #expect(try Settings(yaml: settings.yaml) == settings)
    }

    @Test func missingOptionsKeepTheirDefaults() throws {
        let settings = try Settings(yaml: "width: 8\n")
        var expected = Settings()
        expected.width = 8
        #expect(settings == expected)
    }

    @Test func emptySectionsUnbindEverything() throws {
        let settings = try Settings(yaml: "shortcuts:\nmouse_buttons:\n")
        #expect(settings.shortcuts.bindings.isEmpty)
        #expect(settings.mouseButtons.bindings.isEmpty)
    }

    @Test func shortcutKeysAreLowercased() throws {
        let settings = try Settings(yaml: "shortcuts:\n  P: pen\n")
        #expect(settings.shortcuts.action(for: "p") == .tool(.pen))
    }

    @Test func autoFadeZeroMeansOff() throws {
        #expect(try Settings(yaml: "auto_fade_seconds: 0").autoFadeSeconds == nil)
    }

    @Test(arguments: [
        ("tool: brush", 1), ("color: teal", 1), ("width: 0", 1), ("width: 33", 1), ("width: nan", 1), ("width: wide", 1),
        ("dim_level: 0.9", 1), ("auto_fade_seconds: -1", 1), ("side_buttons: maybe", 1), ("colour: red", 1),
        ("\nhotkey: a", 2), ("hotkey: ctrl+nope", 1), ("hotkey: ctrl", 1), ("hotkey: ctrl+a+b", 1),
        ("mouse_buttons:\n  0: pen", 2), ("mouse_buttons:\n  1: pen", 2), ("mouse_buttons:\n  back: pen", 2),
        ("mouse_buttons:\n  4: brush", 2), ("shortcuts:\n  pp: pen", 2), ("shortcuts:\n  p: fly", 2),
        ("shortcuts:\n  p: pen\n  P: line", 3), ("shortcuts: pen", 1), ("tool:\n  a: b", 1), ("palette_x: 1", 1),
        ("palette_y: 1", 1),
    ])
    func rejectsBadValuesWithTheirLine(text: String, line: Int) {
        #expect {
            _ = try Settings(yaml: text)
        } throws: { error in
            (error as? ConfigError)?.line == line
        }
    }

    @Test func hotKeyParsingIsForgiving() throws {
        let spec = try HotKeySpec(parsing: "Command + Alt + K")
        #expect(spec == HotKeySpec(key: "k", modifiers: [.cmd, .option]))
        #expect(spec.description == "option+cmd+k")
        #expect(spec.displayString == "⌥⌘K")
    }

    @Test func functionKeysNeedNoModifier() throws {
        #expect(try HotKeySpec(parsing: "f5").keyCode == UInt32(kVK_F5))
    }

    @Test func defaultHotKeyDisplay() {
        #expect(HotKeySpec.default.description == "ctrl+option+cmd+a")
        #expect(HotKeySpec.default.displayString == "⌃⌥⌘A")
    }

    @Test func keyCodesMatchTheSystemTable() throws {
        let expected: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("s", kVK_ANSI_S), ("d", kVK_ANSI_D), ("f", kVK_ANSI_F), ("h", kVK_ANSI_H),
            ("g", kVK_ANSI_G), ("z", kVK_ANSI_Z), ("x", kVK_ANSI_X), ("c", kVK_ANSI_C), ("v", kVK_ANSI_V),
            ("b", kVK_ANSI_B), ("q", kVK_ANSI_Q), ("w", kVK_ANSI_W), ("e", kVK_ANSI_E), ("r", kVK_ANSI_R),
            ("y", kVK_ANSI_Y), ("t", kVK_ANSI_T), ("o", kVK_ANSI_O), ("u", kVK_ANSI_U), ("i", kVK_ANSI_I),
            ("p", kVK_ANSI_P), ("l", kVK_ANSI_L), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("n", kVK_ANSI_N),
            ("m", kVK_ANSI_M), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9), ("space", kVK_Space), ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
            ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10),
            ("f11", kVK_F11), ("f12", kVK_F12),
        ]
        for (key, code) in expected {
            #expect(try HotKeySpec(parsing: "ctrl+\(key)").keyCode == UInt32(code), "\(key)")
        }
    }

    /// Each option's comment lines, which come straight above it in the file.
    private func comments(above option: String, in yaml: String) -> String {
        let lines = yaml.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix(option + ":") || $0.hasPrefix("# \(option):") })
        else { return "" }
        return lines[..<index].reversed().prefix { $0.hasPrefix("#") }.joined(separator: "\n")
    }

    @Test func everyOptionHasACommentListingItsValues() {
        let yaml = Settings().yaml
        for option in [
            "tool", "color", "width", "auto_fade_seconds", "dim_level", "hotkey", "side_buttons", "mouse_buttons",
            "shortcuts", "palette_x",
        ] {
            #expect(comments(above: option, in: yaml).contains("Options:") || option == "hotkey"
                || option == "mouse_buttons" || option == "shortcuts", "\(option)")
        }
        for option in ["tool", "mouse_buttons", "shortcuts"] {
            for tool in ToolKind.allCases {
                #expect(comments(above: option, in: yaml).contains(tool.rawValue), "\(option) omits \(tool)")
            }
        }
        for option in ["color", "shortcuts"] {
            for color in RGBA.paletteNames {
                #expect(comments(above: option, in: yaml).contains(color), "\(option) omits \(color)")
            }
        }
        for action in ["thinner", "thicker", "clear"] {
            #expect(comments(above: "shortcuts", in: yaml).contains(action))
        }
        for modifier in HotKeySpec.Modifier.allCases {
            #expect(comments(above: "hotkey", in: yaml).contains(modifier.rawValue))
        }
        #expect(comments(above: "side_buttons", in: yaml).contains("true, false"))
    }

    @Test func thePalettePositionIsShownEvenWhenUnset() throws {
        var settings = Settings()
        #expect(settings.yaml.contains("# palette_x: "))
        #expect(try Settings(yaml: settings.yaml).paletteOrigin == nil)

        settings.paletteOrigin = CGPoint(x: 5, y: 6)
        #expect(settings.yaml.contains("\npalette_x: 5\npalette_y: 6\n"))
    }

    @Test func examplesInTheCommentsAreValid() throws {
        #expect(try HotKeySpec(parsing: "ctrl+option+cmd+a") == .default)
        _ = try HotKeySpec(parsing: "shift+f5")
        _ = try HotKeySpec(parsing: "f1")
        _ = try HotKeySpec(parsing: "ctrl+space")
        _ = try HotKeySpec(parsing: "ctrl+0")
        var settings = Settings()
        settings.width = Settings.widthRange.upperBound
        settings.dimLevel = Settings.dimRange.upperBound
        settings.autoFadeSeconds = Settings.fadeRange.upperBound
        settings.mouseButtons = MouseButtonMap(bindings: [
            Settings.mouseButtonRange.lowerBound: .pen, Settings.mouseButtonRange.upperBound: .pen,
        ])
        #expect(try Settings(yaml: settings.yaml) == settings)
    }

    @Test func paletteNamesMatchThePalette() {
        #expect(RGBA.paletteNames.count == RGBA.palette.count)
        #expect(RGBA.palette[RGBA.paletteNames.firstIndex(of: "blue")!] == .blue)
    }
}
