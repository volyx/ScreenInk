import CoreGraphics
import Foundation
import Testing
@testable import ScreenInkCore

@Suite struct MouseButtonTests {
    @Test func defaultsBindSideButtons() {
        let map = MouseButtonMap.defaults
        #expect(map.tool(forButton: 4) == .pen)
        #expect(map.tool(forButton: 3) == .rectangle)
        #expect(map.tool(forButton: 2) == nil)
    }

    @Test func mapRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(MouseButtonMap.defaults)
        #expect(try JSONDecoder().decode(MouseButtonMap.self, from: data) == .defaults)
    }

    @Test func clickWithoutMovement() {
        let detector = ClickDetector(start: CGPoint(x: 10, y: 10))
        #expect(detector.isClick)
    }

    @Test func jitterIsStillAClick() {
        var detector = ClickDetector(start: CGPoint(x: 10, y: 10))
        detector.move(to: CGPoint(x: 12, y: 11))
        detector.move(to: CGPoint(x: 9, y: 8))
        #expect(detector.isClick)
    }

    @Test func movingToTheToleranceIsADrag() {
        var detector = ClickDetector(start: .zero, tolerance: 4)
        detector.move(to: CGPoint(x: 3.9, y: 0))
        #expect(detector.isClick)
        detector.move(to: CGPoint(x: 4, y: 0))
        #expect(!detector.isClick)
    }

    @Test func returningToTheStartIsStillADrag() {
        var detector = ClickDetector(start: CGPoint(x: 50, y: 50))
        detector.move(to: CGPoint(x: 90, y: 50))
        detector.move(to: CGPoint(x: 50, y: 50))
        #expect(!detector.isClick)
    }

    @Test func clickBasedToolsAreNotDragDrawn() {
        let dragDrawn = ToolKind.allCases.filter(\.isDragDrawn)
        #expect(Set(dragDrawn) == [.pen, .highlighter, .line, .arrow, .rectangle, .ellipse])
    }
}
