// Renders Bundle/AppIcon.icns: a green rounded square with a notepad and a waveform, at every iconset size.
//   swift scripts/make-icon.swift [preview.png]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

/// Draws on a 1024-point canvas scaled to `pixels`.
func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high

    // Body: 824pt squircle on the macOS icon grid, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0.42, 0.66, 0.33))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [rgb(0.55, 0.77, 0.45), rgb(0.42, 0.66, 0.33), rgb(0.30, 0.52, 0.24)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Notepad: warm off-white card with a faint shadow.
    let card = CGRect(x: 262, y: 228, width: 500, height: 580)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0.1, 0.25, 0.05, 0.35))
    ctx.addPath(cardPath)
    ctx.setFillColor(rgb(0.99, 0.97, 0.92))
    ctx.fillPath()
    ctx.restoreGState()

    // Note lines across the top of the card.
    ctx.setLineCap(.round)
    ctx.setLineWidth(30)
    ctx.setStrokeColor(rgb(0.80, 0.78, 0.72))
    for (y, width) in [(706.0, 320.0), (634.0, 250.0)] {
        ctx.move(to: CGPoint(x: 342, y: y))
        ctx.addLine(to: CGPoint(x: 342 + width, y: y))
    }
    ctx.strokePath()

    // Waveform in the accent green.
    let heights: [CGFloat] = [70, 150, 230, 130, 190, 90, 50]
    let spacing: CGFloat = 56, barWidth: CGFloat = 32, centerY: CGFloat = 410
    let startX = 512 - spacing * CGFloat(heights.count - 1) / 2
    ctx.setFillColor(rgb(0.36, 0.60, 0.28))
    for (i, h) in heights.enumerated() {
        let x = startX + spacing * CGFloat(i) - barWidth / 2
        let bar = CGRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(pixels: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    writePNG(render(pixels: size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let icns = root.appendingPathComponent("Bundle/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icns.path)")

if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    writePNG(render(pixels: 1024), to: preview)
    print("Wrote \(preview.path)")
}
