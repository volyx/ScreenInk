import AppKit
import ScreenInkCore

/// `ScreenInk --screenshots <dir>`: renders the README screenshots off-screen. A sample slide
/// stands in for the desktop, annotated through the real tools, with the real palette on top,
/// so nothing from the user's screen ends up in the images.
@MainActor
enum Screenshots {
    private static let size = NSSize(width: 1280, height: 800)

    static func run(outputDirectory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let toolState = ToolState()
        let canvas = CanvasView(frame: NSRect(origin: .zero, size: size), document: Document(), toolState: toolState)
        annotate(canvas, toolState: toolState)
        toolState.tool = .pen
        toolState.colorIndex = 0
        let palette = ToolPalette(toolState: toolState).renderImage()

        let shots: [(name: String, dim: Double)] = [("drawing.png", 0), ("dimmed.png", 0.35)]
        for shot in shots {
            toolState.dimLevel = shot.dim
            let image = compose(slide: slide(), canvas: canvas.snapshot(), palette: palette)
            let rep = NSBitmapImageRep(cgImage: image)
            let url = outputDirectory.appendingPathComponent(shot.name)
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            } catch {
                print("screenshots: couldn't write \(url.path): \(error)")
                return false
            }
            print("screenshots: wrote \(url.path)")
        }
        return true
    }

    // MARK: Annotations

    private static func annotate(_ canvas: CanvasView, toolState: ToolState) {
        // Circle the best bar and call it out.
        toolState.width = 6
        toolState.colorIndex = 0  // red
        toolState.tool = .ellipse
        canvas.simulateGesture([CGPoint(x: 600, y: 182), CGPoint(x: 760, y: 262)])
        toolState.tool = .arrow
        canvas.simulateGesture([CGPoint(x: 850, y: 205), CGPoint(x: 770, y: 232)], option: true)
        toolState.tool = .text
        canvas.simulateGesture([CGPoint(x: 820, y: 150)])
        canvas.editingTextView?.insertText(
            "Best quarter yet!", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.endTextEditing()

        // Number the bullets.
        toolState.width = 4
        toolState.colorIndex = 4  // blue
        toolState.tool = .badge
        for y in [313.0, 373, 433] { canvas.simulateGesture([CGPoint(x: 830, y: y)]) }

        // Highlight one bullet, underline another.
        toolState.colorIndex = 2  // yellow
        toolState.width = 7
        toolState.tool = .highlighter
        canvas.simulateGesture((0...40).map { CGPoint(x: 862 + Double($0) * 9, y: 374) })
        toolState.colorIndex = 3  // green
        toolState.width = 4
        toolState.tool = .pen
        canvas.simulateGesture(
            (0...60).map { i in
                let t = Double(i) / 60
                return CGPoint(x: 862 + t * 210, y: 452 + sin(t * .pi * 6) * 3)
            })
    }

    // MARK: Composition

    /// Slide at the bottom, the canvas over it (as the overlay window is over the desktop),
    /// then the palette panel on the left.
    private static func compose(slide: CGImage, canvas: CGImage, palette: NSBitmapImageRep?) -> CGImage {
        let scale = CGFloat(canvas.width) / size.width
        let context = CGContext(
            data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let full = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        context.draw(slide, in: full)
        context.draw(canvas, in: full)
        if let palette, let image = palette.cgImage {
            let width = palette.size.width * scale
            let height = palette.size.height * scale
            let frame = CGRect(x: 24 * scale, y: (CGFloat(canvas.height) - height) / 2, width: width, height: height)
            let path = CGPath(roundedRect: frame, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 18 * scale,
                color: NSColor.black.withAlphaComponent(0.3).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor(white: 0.16, alpha: 0.92).cgColor)
            context.fillPath()
            context.restoreGState()
            context.draw(image, in: frame)
        }
        return context.makeImage()!
    }

    /// A sample presentation slide: a title, a bar chart and three bullets.
    private static func slide() -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = graphics
        // Draw with a top-left origin, like the canvas.
        graphics.cgContext.translateBy(x: 0, y: size.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
        NSGraphicsContext.current = flipped

        NSColor(white: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(red: 0.20, green: 0.36, blue: 0.85, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size.width, height: 10).fill()

        let ink = NSColor(white: 0.12, alpha: 1)
        let muted = NSColor(white: 0.45, alpha: 1)
        draw("Quarterly sign-ups", at: CGPoint(x: 160, y: 70), size: 44, weight: .bold, color: ink)
        draw("Product review · 2026", at: CGPoint(x: 160, y: 130), size: 22, weight: .regular, color: muted)

        let baseline: CGFloat = 640
        let bars: [(label: String, height: CGFloat)] = [("Q1", 170), ("Q2", 230), ("Q3", 290), ("Q4", 410)]
        for (index, bar) in bars.enumerated() {
            let x = 180 + CGFloat(index) * 150
            let isLast = index == bars.count - 1
            (isLast ? NSColor(red: 0.20, green: 0.36, blue: 0.85, alpha: 1) : NSColor(white: 0.78, alpha: 1)).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: baseline - bar.height, width: 100, height: bar.height), xRadius: 6,
                yRadius: 6
            ).fill()
            draw(bar.label, at: CGPoint(x: x + 36, y: baseline + 14), size: 20, weight: .medium, color: muted)
        }
        NSColor(white: 0.7, alpha: 1).setFill()
        NSRect(x: 160, y: baseline, width: 600, height: 2).fill()

        let bullets = ["Self-serve onboarding launched", "Referral program doubled invites", "Churn down to 2.1%"]
        for (index, bullet) in bullets.enumerated() {
            draw(bullet, at: CGPoint(x: 862, y: 300 + CGFloat(index) * 60), size: 22, weight: .regular, color: ink)
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private static func draw(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        (string as NSString).draw(
            at: point,
            withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
}
