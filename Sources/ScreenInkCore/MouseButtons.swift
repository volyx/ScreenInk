import CoreGraphics

extension ToolKind {
    /// Tools whose gesture is a drag, so a click without movement means nothing to them.
    /// The pen's dot is the exception, which quick draw gives up in favor of click-to-exit.
    public var isDragDrawn: Bool {
        switch self {
        case .pen, .highlighter, .line, .arrow, .rectangle, .ellipse: true
        case .text, .badge, .eraser, .select: false
        }
    }
}

/// Which tool each extra mouse button starts, keyed by `NSEvent.buttonNumber`.
/// Stored as data so a Settings pane can rebind them (PLAN.md §5).
public struct MouseButtonMap: Codable, Hashable, Sendable {
    public var bindings: [Int: ToolKind]

    public init(bindings: [Int: ToolKind]) {
        self.bindings = bindings
    }

    public func tool(forButton button: Int) -> ToolKind? {
        bindings[button]
    }

    /// Measured on an MX Master 3S: the upper side button (Forward) is 4, the lower (Back) is 3.
    public static let defaults = MouseButtonMap(bindings: [4: .pen, 3: .rectangle])
}

/// Tells a click from a drag. Any excursion past `tolerance` makes it a drag,
/// even if the pointer comes back to where it started.
public struct ClickDetector: Sendable {
    public static let defaultTolerance: CGFloat = 4

    private let start: CGPoint
    private let tolerance: CGFloat
    private var farthest: CGFloat = 0

    public init(start: CGPoint, tolerance: CGFloat = ClickDetector.defaultTolerance) {
        self.start = start
        self.tolerance = tolerance
    }

    public mutating func move(to point: CGPoint) {
        farthest = max(farthest, hypot(point.x - start.x, point.y - start.y))
    }

    public var isClick: Bool { farthest < tolerance }
}
