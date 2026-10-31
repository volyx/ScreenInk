// Draws the app icon and writes Resources/AppIcon.icns. Run with `make icon`.
// Every size is drawn natively (no resampling); geometry is on Apple's 1024-pt icon grid.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func channel(_ shift: UInt32) -> CGFloat {
        let x = CGFloat(a >> shift & 0xFF), y = CGFloat(b >> shift & 0xFF)
        return (x + (y - x) * t) / 255
    }
    return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
}

let inkStart: UInt32 = 0xFF4D5E
let inkEnd: UInt32 = 0xFFB020

/// A rounded bar of slide content.
func fillBar(_ context: CGContext, _ rect: CGRect, _ fill: CGColor) {
    let radius = min(rect.width, rect.height) / 2
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(fill)
    context.fillPath()
}

/// Draws the icon into `context`, in 1024-pt top-left coordinates: the tile is the screen, with a
/// chart on a slide circled in ink. Below 64 pixels the fine detail is left out and the ink thickened.
func drawIcon(_ context: CGContext, pixels: Int) {
    let isSmall = pixels < 64
    // Shadows ignore the context's transform, so they need scaling and flipping by hand.
    let scale = CGFloat(pixels) / 1024
    func setShadow(drop: CGFloat, blur: CGFloat, alpha: CGFloat) {
        context.setShadow(
            offset: CGSize(width: 0, height: -drop * scale), blur: blur * scale, color: color(0x000000, alpha))
    }

    // Squircle-ish tile with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    setShadow(drop: 10, blur: 24, alpha: 0.35)
    context.addPath(tilePath)
    context.setFillColor(color(0x232C7A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x4A5FE8), color(0x161C5C)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // The slide: a chart to circle, with faint lines of text above and below it.
    if !isSmall {
        fillBar(context, CGRect(x: 250, y: 212, width: 400, height: 34), color(0xFFFFFF, 0.28))
        fillBar(context, CGRect(x: 250, y: 764, width: 524, height: 34), color(0xFFFFFF, 0.28))
        fillBar(context, CGRect(x: 250, y: 832, width: 330, height: 34), color(0xFFFFFF, 0.28))
    }
    let barWidth: CGFloat = isSmall ? 74 : 58
    for (index, height) in (isSmall ? [80, 135, 190] : [76, 128, 180] as [CGFloat]).enumerated() {
        let x = 512 + CGFloat(index - 1) * (barWidth + 22) - barWidth / 2
        fillBar(context, CGRect(x: x, y: 590 - height, width: barWidth, height: height), color(0xFFFFFF, 0.95))
    }

    // The ink: one hand-drawn loop that widens as it goes, so its end passes outside its start.
    let steps = 720
    var inkEndPoint = CGPoint.zero
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let angle = (-72 + 387 * t) * .pi / 180
        let point = CGPoint(x: 512 + (262 + 56 * t) * cos(angle), y: 496 + (156 + 52 * t) * sin(angle))
        let radius = (isSmall ? 24 : 7) + (isSmall ? 20 : 23) * sin(min(t * 1.6, 1) * .pi / 2)
        context.setFillColor(mix(inkStart, inkEnd, t))
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        inkEndPoint = point
    }
    context.restoreGState()

    // Pen, its tip at the end of the stroke, body up and to the right.
    context.saveGState()
    context.translateBy(x: inkEndPoint.x, y: inkEndPoint.y)
    context.rotate(by: -.pi / 4)
    setShadow(drop: 8, blur: 16, alpha: 0.3)
    let body = CGMutablePath()
    body.move(to: .zero)
    body.addLine(to: CGPoint(x: 78, y: -40))
    body.addLine(to: CGPoint(x: 186, y: -40))
    body.addArc(center: CGPoint(x: 186, y: 0), radius: 40, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    body.addLine(to: CGPoint(x: 78, y: 40))
    body.closeSubpath()
    context.addPath(body)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    // Ferrule band and the inked nib.
    context.setFillColor(color(0xD5DAE8))
    context.fill(CGRect(x: 78, y: -40, width: 34, height: 80))
    let nib = CGMutablePath()
    nib.move(to: .zero)
    nib.addLine(to: CGPoint(x: 30, y: -15.4))
    nib.addLine(to: CGPoint(x: 30, y: 15.4))
    nib.closeSubpath()
    context.addPath(nib)
    context.setFillColor(color(inkEnd))
    context.fillPath()
    context.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    drawIcon(context, pixels: pixels)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(url.path)") }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
writePNG(render(pixels: 1024), to: root.appendingPathComponent("docs/images/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns and docs/images/icon.png")
