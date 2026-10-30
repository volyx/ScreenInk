import AppKit
import ScreenInkCore

/// `ScreenInk --self-test <dir>`: exercises the real canvas, tools and rendering off-screen,
/// writes PNGs to `dir`, and checks pixels and document state. Used where the UI can't be
/// driven directly (CI, no Accessibility permission).
@MainActor
enum SelfTest {
    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func run(outputDirectory: URL) -> Bool {
        failures = []
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let toolState = ToolState()
        let size = NSSize(width: 400, height: 300)
        let document = Document()
        let canvas = CanvasView(frame: NSRect(origin: .zero, size: size), document: document, toolState: toolState)
        func saveCanvas(_ name: String) { save(canvas.snapshot(), name, in: outputDirectory) }

        // 1. Pen stroke: live raster vs committed vector, orientation, undo/redo.
        let wave = (0...60).map { i -> CGPoint in
            let t = Double(i) / 60
            return CGPoint(x: 20 + t * 360, y: 20 + t * 260 + sin(t * 12) * 20)
        }
        canvas.currentTool.mouseDown(PointerInput(point: wave[0]), in: canvas)
        for point in wave.dropFirst().dropLast() { canvas.currentTool.mouseDragged(PointerInput(point: point), in: canvas) }
        let live = canvas.snapshot()
        canvas.currentTool.mouseUp(PointerInput(point: wave.last!), in: canvas)
        let committed = canvas.snapshot()
        save(live, "1-live.png", in: outputDirectory)
        save(committed, "2-committed.png", in: outputDirectory)
        check(isInk(committed, at: wave[0], viewSize: size), "no ink at stroke start (orientation?)")
        check(!isInk(committed, at: CGPoint(x: 20, y: 280), viewSize: size), "ink at bottom-left (flipped?)")
        let difference = differingFraction(live, committed)
        check(difference < 0.01, "live vs committed differ in \(difference * 100)% of pixels")
        document.undo()
        check(inkFraction(canvas.snapshot()) == 0, "undo left ink behind")
        document.redo()
        check(differingFraction(canvas.snapshot(), committed) < 0.001, "redo didn't restore the stroke")
        document.removeAll()

        // 2. Every tool, drawn through the same dispatch the mouse uses.
        toolState.colorIndex = 4  // blue
        toolState.tool = .rectangle
        canvas.simulateGesture([CGPoint(x: 30, y: 30), CGPoint(x: 90, y: 60), CGPoint(x: 150, y: 90)])
        toolState.tool = .ellipse
        canvas.simulateGesture([CGPoint(x: 200, y: 30), CGPoint(x: 290, y: 75)], shift: true)
        toolState.tool = .line
        canvas.simulateGesture([CGPoint(x: 30, y: 130), CGPoint(x: 150, y: 138)], shift: true)
        toolState.tool = .arrow
        canvas.simulateGesture([CGPoint(x: 200, y: 140), CGPoint(x: 360, y: 140)], option: true)
        toolState.colorIndex = 0
        toolState.tool = .badge
        canvas.simulateGesture([CGPoint(x: 330, y: 50)])
        canvas.simulateGesture([CGPoint(x: 370, y: 50)])
        toolState.tool = .highlighter
        canvas.simulateGesture((0...20).map { CGPoint(x: 30 + Double($0) * 6, y: 200) })
        toolState.tool = .text
        canvas.simulateGesture([CGPoint(x: 200, y: 200)])
        canvas.editingTextView?.insertText("Hello, ScreenInk", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.endTextEditing()
        saveCanvas("4-all-tools.png")

        let kinds = document.annotations.map(\.kind)
        check(
            kinds == [.rectangle, .ellipse, .line, .arrow, .badge, .badge, .stroke, .text],
            "unexpected annotations: \(kinds)")
        let badges = document.annotations.compactMap { annotation -> Int? in
            if case let .badge(_, number, _, _) = annotation.geometry { return number }
            return nil
        }
        check(badges == [1, 2], "badges numbered \(badges)")
        if case let .ellipse(rect) = document.annotations[safe: 1]?.geometry {
            check(rect.width == rect.height, "Shift didn't make a circle")
        }
        if case let .line(from, to) = document.annotations[safe: 2]?.geometry {
            check(from.y == to.y, "Shift didn't snap the line horizontal")
        }
        if case let .arrow(_, _, control) = document.annotations[safe: 3]?.geometry {
            check(control != nil, "⌥ didn't curve the arrow")
        }
        check(document.annotations[safe: 6]?.style.blend == .multiply, "highlighter isn't multiply-blended")
        if case let .text(_, string, _) = document.annotations.last?.geometry {
            check(string == "Hello, ScreenInk", "text was \(string)")
        }

        // 3. Select and move the rectangle by dragging its edge.
        let rectangleID = document.annotations[0].id
        let before = document.annotations[0].bounds
        toolState.tool = .select
        canvas.simulateGesture([CGPoint(x: 30, y: 60), CGPoint(x: 60, y: 70), CGPoint(x: 80, y: 80)])
        check(canvas.selection == [rectangleID], "click didn't select the rectangle")
        let after = document.annotations.first { $0.id == rectangleID }?.bounds ?? .null
        check(after.minX - before.minX == 50 && after.minY - before.minY == 20, "move went to \(after)")

        // 4. A color key recolors the selection.
        canvas.perform(.color(3))
        check(document.annotations.first { $0.id == rectangleID }?.style.color == RGBA.palette[3], "recolor failed")

        // 5. Erase the ellipse by crossing its outline; one undo brings it back.
        let ellipseID = document.annotations[1].id
        toolState.tool = .eraser
        canvas.simulateGesture([CGPoint(x: 245, y: 20), CGPoint(x: 245, y: 40)])
        check(!document.annotations.contains { $0.id == ellipseID }, "eraser missed the ellipse")
        check(document.annotations.count == 7, "eraser removed \(8 - document.annotations.count) annotations")
        document.undo()
        check(document.annotations.contains { $0.id == ellipseID }, "undo didn't restore the erased ellipse")
        saveCanvas("5-after-edits.png")

        // 6. A single pen click leaves a dot.
        toolState.tool = .pen
        canvas.simulateGesture([CGPoint(x: 200, y: 260)])
        check(isInk(canvas.snapshot(), at: CGPoint(x: 200, y: 260), viewSize: size), "click didn't leave a dot")

        // 7. Dimming darkens empty areas behind the ink, and turns off again.
        let empty = CGPoint(x: 4, y: 4)
        check(alpha(canvas.snapshot(), at: empty, viewSize: size) == 0, "corner isn't empty before dimming")
        toolState.dimLevel = 0.35
        let dimmed = canvas.snapshot()
        save(dimmed, "6-dimmed.png", in: outputDirectory)
        let dimAlpha = alpha(dimmed, at: empty, viewSize: size)
        check(abs(dimAlpha - 89) <= 10, "dim alpha \(dimAlpha), expected about 89")
        check(isInk(dimmed, at: CGPoint(x: 200, y: 260), viewSize: size), "dimming hid the ink")
        toolState.dimLevel = 0
        check(alpha(canvas.snapshot(), at: empty, viewSize: size) == 0, "dimming didn't turn off")

        // 8. Quick draw: a click without a drag asks to exit and leaves nothing; drags still draw.
        let quickDocument = Document()
        let quick = CanvasView(frame: NSRect(origin: .zero, size: size), document: quickDocument, toolState: toolState)
        var plainClicks = 0
        quick.onPlainClick = { plainClicks += 1 }
        for kind in [ToolKind.pen, .rectangle] {
            toolState.tool = kind
            plainClicks = 0
            quick.simulateGesture([CGPoint(x: 100, y: 100)])
            quick.simulateGesture([CGPoint(x: 100, y: 100), CGPoint(x: 102, y: 101)])
            check(plainClicks == 2, "\(kind) clicks fired the handler \(plainClicks) times")
            check(quickDocument.annotations.isEmpty, "\(kind) click left an annotation")
            check(inkFraction(quick.snapshot()) == 0, "\(kind) click left ink behind")
            plainClicks = 0
            quick.simulateGesture([CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 80), CGPoint(x: 150, y: 120)])
            check(plainClicks == 0, "\(kind) drag counted as a click")
            check(quickDocument.annotations.count == 1, "\(kind) drag didn't draw")
            quick.simulateGesture([CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 90), CGPoint(x: 50, y: 50)])
            check(plainClicks == 0, "\(kind) drag back to its start counted as a click")
            quickDocument.removeAll()
        }
        toolState.tool = .badge
        plainClicks = 0
        quick.simulateGesture([CGPoint(x: 100, y: 100)])
        check(plainClicks == 0, "a badge click counted as a plain click")
        check(quickDocument.annotations.map(\.kind) == [.badge], "a badge click didn't place a badge")

        checkConfigFile(in: outputDirectory)

        print("self-test: live/committed pixel difference \(String(format: "%.4f%%", difference * 100))")
        for failure in failures { print("FAIL: \(failure)") }
        print(failures.isEmpty ? "self-test: PASS" : "self-test: FAIL")
        return failures.isEmpty
    }

    /// 9. The config file: created on first run, edits reach the app, and a bad file is never overwritten.
    private static func checkConfigFile(in outputDirectory: URL) {
        let url = outputDirectory.appendingPathComponent("config-test/config.yml")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        // The template a new install gets, to read alongside the PNGs.
        try? Settings().yaml.write(
            to: outputDirectory.appendingPathComponent("config-sample.yml"), atomically: true, encoding: .utf8)
        func onDisk() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func replace(_ text: String) { try? text.write(to: url, atomically: true, encoding: .utf8) }
        /// Runs the main queue until `condition` holds, as the app's event loop would.
        func wait(for condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }

        var initial = Settings()
        initial.width = 6
        let config = ConfigFile(url: url)
        let loaded = config.load(initial: initial)
        check(loaded == initial, "first run didn't use the initial settings")
        check(onDisk() == initial.yaml, "first run didn't create the file")

        var received: Settings?
        var problems: [String] = []
        config.onExternalChange = { received = $0 }
        config.onProblem = { problems.append($0) }

        // An atomic save, as most editors do it.
        replace("# my note\nwidth: 12\n")
        check(wait { received?.width == 12 }, "an atomic edit wasn't picked up")

        // An in-place write to the same file, as shells and some editors do it.
        received = nil
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("dim_level: 0.5\n".utf8))
            try? handle.close()
        }
        check(wait { received?.dimLevel == 0.5 }, "an in-place edit wasn't picked up")

        // Saving the settings the file already holds keeps the file, and its comments, as they are.
        let commented = onDisk()
        config.save(received ?? Settings())
        config.flush()
        check(onDisk() == commented, "an unchanged save rewrote the file")

        // A real change is written out.
        var changed = received ?? Settings()
        changed.width = 3
        config.save(changed)
        config.flush()
        check((try? Settings(yaml: onDisk())) == changed, "an in-app change wasn't saved")

        // A broken file is reported once, keeps its contents, and isn't overwritten by in-app changes.
        let broken = "width: wide\n"
        replace(broken)
        check(wait { !problems.isEmpty }, "a broken file wasn't reported")
        check(config.problem?.contains("Line 1") == true, "the problem didn't name its line: \(config.problem ?? "none")")
        changed.width = 4
        config.save(changed)
        config.flush()
        check(onDisk() == broken, "an in-app change overwrote a broken file")
        check(problems.count == 1, "the problem was reported \(problems.count) times")

        // Fixing the file clears the problem and applies it.
        received = nil
        replace("width: 9\n")
        check(wait { received?.width == 9 }, "the fixed file wasn't picked up")
        check(config.problem == nil, "the problem outlived its fix")

        // An edit that hasn't been noticed yet beats a pending in-app change.
        replace("width: 20\n")
        changed.width = 5
        config.save(changed)
        config.flush()
        check(onDisk() == "width: 20\n", "an in-app change overwrote an unseen edit")

        // ToolState saves app changes, but not settings that came from the file.
        let state = ToolState(settings: initial)
        var saves = 0
        state.onSettingsChange = { _ in saves += 1 }
        var observed = 0
        state.observe { observed += 1 }
        var fromFile = initial
        fromFile.width = 16
        fromFile.colorIndex = 3
        state.apply(fromFile)
        check(saves == 0, "applying the file's settings saved them back")
        check(observed == 1, "applying settings notified observers \(observed) times")
        check(state.settings == fromFile, "ToolState didn't take on the file's settings")
        state.width = 8
        check(saves == 1, "an in-app change wasn't saved")

        // Earlier versions' settings carry over.
        let defaults = UserDefaults(suiteName: "ScreenInkSelfTest")!
        defaults.removePersistentDomain(forName: "ScreenInkSelfTest")
        defaults.set("rectangle", forKey: "Tool")
        defaults.set(2, forKey: "ColorIndex")
        defaults.set(3.0, forKey: "AutoFadeSeconds")
        defaults.set("0.5", forKey: "DimLevel")
        defaults.set(true, forKey: "SideButtonsEnabled")
        defaults.set("{1775, 274}", forKey: "PaletteOrigin")
        let legacy = Settings.legacy(from: defaults)
        defaults.removePersistentDomain(forName: "ScreenInkSelfTest")
        check(
            legacy.tool == .rectangle && legacy.colorIndex == 2 && legacy.autoFadeSeconds == 3 && legacy.dimLevel == 0.5
                && legacy.sideButtonsEnabled && legacy.width == 4,
            "legacy settings didn't carry over: \(legacy)")
        check(legacy.paletteOrigin == CGPoint(x: 1775, y: 274), "legacy palette position was \(String(describing: legacy.paletteOrigin))")
        check((try? Settings(yaml: legacy.yaml)) == legacy, "migrated settings don't survive the file")
    }

    private static func save(_ image: CGImage, _ name: String, in directory: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// `point` is in top-left view coordinates; rows in `pixels` run top to bottom.
    private static func isInk(_ image: CGImage, at point: CGPoint, viewSize: NSSize) -> Bool {
        alpha(image, at: point, viewSize: viewSize) > 128
    }

    private static func alpha(_ image: CGImage, at point: CGPoint, viewSize: NSSize) -> Int {
        let scale = CGFloat(image.width) / viewSize.width
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        return Int(pixels(image)[(y * image.width + x) * 4 + 3])
    }

    private static func inkFraction(_ image: CGImage) -> Double {
        let data = pixels(image)
        let inked = stride(from: 3, to: data.count, by: 4).filter { data[$0] > 0 }.count
        return Double(inked) / Double(image.width * image.height)
    }

    private static func differingFraction(_ a: CGImage, _ b: CGImage) -> Double {
        let (pa, pb) = (pixels(a), pixels(b))
        guard pa.count == pb.count else { return 1 }
        var differing = 0
        for i in stride(from: 3, to: pa.count, by: 4) where abs(Int(pa[i]) - Int(pb[i])) > 64 {
            differing += 1
        }
        return Double(differing) / Double(a.width * a.height)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension CanvasView {
    /// Composites the canvas layers the same way the screen does, on a white background.
    func snapshot() -> CGImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let context = CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        for view in subviews where !view.isHidden {
            if view is DimView || view is AnnotationsView || view is OverlayLayerView, let layer = view.layer {
                // CALayer.render draws in the layer's own (flipped) space; flip to bitmap space.
                context.saveGState()
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                layer.render(in: context)
                context.restoreGState()
            } else if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let image = rep.cgImage {
                    context.setAlpha(view.alphaValue)
                    context.draw(image, in: view.frame)
                    context.setAlpha(1)
                }
            }
        }
        return context.makeImage()!
    }
}
