// Renders the Dune II app icon ("a single sun setting over Arrakis dunes") to a PNG.
// Arrakis orbits one star (Canopus), so the scene has a single sun.
//
// Usage:  swift gen-app-icon.swift <out.png> [--ios|--macos] [size]
//   --ios    full-bleed opaque square (iOS masks it to a squircle itself).  [default]
//   --macos  rounded-rect with a transparent margin (macOS icons are pre-shaped).
//
// Pure CoreGraphics/ImageIO so it has no SwiftPM deps; the art is original (no game assets).
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: gen-app-icon.swift <out.png> [--ios|--macos] [size]\n".utf8)); exit(2) }
let outPath = args[1]
let macos = args.contains("--macos")
let pixels = args.dropFirst(2).compactMap { Int($0) }.first ?? 1024

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func grad(_ stops: [(Double, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map(\.1) as CFArray, locations: stops.map { CGFloat($0.0) })!
}

guard
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else { fatalError("no context") }

// Map a 0…1024 design space (origin bottom-left) onto the pixel canvas, inset+rounded for macOS.
let D = 1024.0
ctx.scaleBy(x: Double(pixels) / D, y: Double(pixels) / D)
if macos {
    let inset = D * 0.092
    let rect = CGRect(x: inset, y: inset, width: D - 2 * inset, height: D - 2 * inset)
    let r = rect.width * 0.2237
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
}
ctx.interpolationQuality = .high

// ── Sky: a dusk gradient, gold at the horizon up to night indigo ──────────────
ctx.drawLinearGradient(
    grad([
        (0.00, c(247, 197, 92)), (0.16, c(226, 126, 46)), (0.40, c(150, 60, 78)),
        (0.68, c(58, 35, 78)), (1.00, c(26, 21, 52)),
    ]),
    start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: D), options: []
)

// A few faint stars up high.
for (x, y, a) in [(150.0, 930.0, 0.7), (300.0, 860.0, 0.4), (760.0, 950.0, 0.6), (880.0, 840.0, 0.45), (620.0, 905.0, 0.35), (470.0, 980.0, 0.5)] {
    ctx.setFillColor(c(255, 255, 255, a))
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: 5, height: 5))
}

// ── The single sun (Canopus), low and large, setting behind the dunes ─────────
let sun = CGPoint(x: 470, y: 452)
ctx.drawRadialGradient(
    grad([(0.0, c(255, 236, 184, 0.95)), (0.55, c(255, 196, 110, 0.45)), (1.0, c(255, 150, 70, 0))]),
    startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 470, options: []
)
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: sun.x - 150, y: sun.y - 150, width: 300, height: 300))
ctx.clip()
ctx.drawLinearGradient(
    grad([(0.0, c(255, 249, 220)), (1.0, c(255, 205, 120))]),
    start: CGPoint(x: sun.x, y: sun.y + 150), end: CGPoint(x: sun.x, y: sun.y - 150), options: []
)
ctx.restoreGState()

// ── Dunes: layered ridges (back→front), each with a sunlit crest highlight ────
// The dunes are drawn after the sun, so the lower sun is occluded — a setting sun.
func dune(_ pts: [CGPoint], fill: CGColor, crest: CGColor, crestWidth: CGFloat = 8) {
    let crestPath = CGMutablePath()
    crestPath.move(to: CGPoint(x: 0, y: pts[0].y))
    var i = 0
    while i + 3 < pts.count { crestPath.addCurve(to: pts[i + 3], control1: pts[i + 1], control2: pts[i + 2]); i += 3 }
    let fillPath = crestPath.mutableCopy()!
    fillPath.addLine(to: CGPoint(x: D, y: 0))
    fillPath.addLine(to: CGPoint(x: 0, y: 0))
    fillPath.closeSubpath()
    ctx.addPath(fillPath); ctx.setFillColor(fill); ctx.fillPath()
    ctx.addPath(crestPath); ctx.setStrokeColor(crest); ctx.setLineWidth(crestWidth); ctx.setLineCap(.butt); ctx.strokePath()
}
dune([CGPoint(x: 0, y: 392), CGPoint(x: 300, y: 336), CGPoint(x: 700, y: 452), CGPoint(x: 1024, y: 372)],
     fill: c(184, 94, 42), crest: c(255, 222, 152, 0.55))
dune([CGPoint(x: 0, y: 300), CGPoint(x: 360, y: 374), CGPoint(x: 720, y: 262), CGPoint(x: 1024, y: 332)],
     fill: c(132, 60, 30), crest: c(245, 170, 88, 0.5))
dune([CGPoint(x: 0, y: 214), CGPoint(x: 330, y: 166), CGPoint(x: 700, y: 272), CGPoint(x: 1024, y: 196)],
     fill: c(86, 40, 22), crest: c(208, 112, 56, 0.45))
dune([CGPoint(x: 0, y: 118), CGPoint(x: 300, y: 192), CGPoint(x: 680, y: 148), CGPoint(x: 1024, y: 96)],
     fill: c(46, 21, 13), crest: c(120, 60, 32, 0.4))

// A couple of faint spice glints on the foreground sand.
for (x, y) in [(200.0, 64.0), (820.0, 78.0)] {
    ctx.drawRadialGradient(
        grad([(0.0, c(255, 168, 70, 0.85)), (1.0, c(255, 168, 70, 0))]),
        startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: 24, options: []
    )
}

guard let img = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { fatalError("no dest") }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(outPath) (\(pixels)px, \(macos ? "macOS rounded" : "iOS full-bleed"))")
