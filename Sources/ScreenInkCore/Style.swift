import CoreGraphics

/// A color stored as sRGB components, independent of AppKit.
public struct RGBA: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let red = RGBA(red: 0.96, green: 0.23, blue: 0.21)
    public static let orange = RGBA(red: 1.0, green: 0.58, blue: 0.0)
    public static let yellow = RGBA(red: 1.0, green: 0.84, blue: 0.0)
    public static let green = RGBA(red: 0.2, green: 0.78, blue: 0.35)
    public static let blue = RGBA(red: 0.0, green: 0.48, blue: 1.0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)
    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let purple = RGBA(red: 0.69, green: 0.32, blue: 0.87)
    public static let pink = RGBA(red: 1.0, green: 0.18, blue: 0.57)

    /// The swatches on the palette, bound to keys 1–9.
    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .white, .black]

    /// The names the config file uses for `palette`, in the same order.
    public static let paletteNames = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "white", "black"]
}

public enum Blend: String, Codable, Hashable, Sendable {
    case normal
    case multiply
}

public struct Style: Codable, Hashable, Sendable {
    public var color: RGBA
    /// Base line width in points; pressure scales it per segment.
    public var width: Double
    /// Applied to the whole annotation layer, so overlapping segments don't darken.
    public var opacity: Double
    public var blend: Blend

    public init(color: RGBA, width: Double, opacity: Double = 1, blend: Blend = .normal) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.blend = blend
    }

    public static let defaultPen = Style(color: .red, width: 4)
}
