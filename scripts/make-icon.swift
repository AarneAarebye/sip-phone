#!/usr/bin/env swift
// Draws the SIP Phone app icon and writes the full macOS AppIcon set.
//
//   swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Deterministic: plain CoreGraphics, sRGB, no fonts and no system glyphs. The handset is our own Bézier
// drawing (SF Symbols must not be used in app icons). Every size is rendered natively at its pixel size;
// at 32 px and below the frame stroke is thickened, and at 16 px the dot is dropped (it would only be a
// smudge next to the handset).
//
// Layout on the 1024 canvas (y from the top), same family as the Dossiary icon:
//   body   rounded square 100…924, radius 185, #1B2426, soft drop shadow below
//   frame  rounded-square outline, centre line inset 74 (outer edge inset 58), stroke 32, #388B6C
//   glyph  phone handset, #4FE0A6, slightly up-left of centre
//   dot    filled circle r 36 at (716, 716), #4FE0A6

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

let bodyColor = color(0x1B2426)
let frameColor = color(0x388B6C)
let glyphColor = color(0x4FE0A6)

/// The handset in 1024-canvas units (y down). A thick arc (the grip) bowing to the lower left, with a
/// rounded cup at each end that flares towards the inside of the curve: earpiece top-left, mouthpiece
/// bottom-right. Built from strokes with round caps, so every outer corner is rounded.
func drawHandset(_ ctx: CGContext) {
    let center = CGPoint(x: 572, y: 386)   // centre of the grip arc (upper right of the glyph)
    let radius: CGFloat = 220               // grip centre-line radius
    let grip: CGFloat = 80                  // grip thickness
    let spread: CGFloat = 58                // half the arc, degrees either side of the 135° diagonal
    let cupLength: CGFloat = 80             // how far each cup reaches towards the arc centre
    let cupWidth: CGFloat = 128             // cup thickness (wider than the grip)

    func point(_ degrees: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
    let start = 135 - spread   // mouthpiece end (bottom right)
    let end = 135 + spread     // earpiece end (top left)

    ctx.saveGState()
    ctx.setStrokeColor(glyphColor)
    ctx.setLineJoin(.round)

    // Grip.
    ctx.setLineWidth(grip)
    // Round caps: each cap circle sits inside the cup's own round end (internally tangent), so the joint
    // between grip and cup has no corner poking out.
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180,
               clockwise: false)
    ctx.strokePath()

    // Cups: short radial strokes with round caps, tilted slightly back along the arc so they read as the
    // rounded ear/mouth pieces of a classic handset.
    ctx.setLineWidth(cupWidth)
    ctx.setLineCap(.round)
    for (angle, tilt) in [(start, -7.0), (end, 7.0)] as [(CGFloat, CGFloat)] {
        let outer = point(angle, radius + grip / 2 - cupWidth / 2)
        let inner = point(angle + tilt, radius - cupLength)
        ctx.move(to: outer)
        ctx.addLine(to: inner)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)   // draw in 1024 units, y from the top
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // Body with soft drop shadow (shadow offsets are in device space, y up).
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 22 * scale,
                  color: color(0x000000, alpha: 0.32))
    ctx.addPath(body)
    ctx.setFillColor(bodyColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Frame. At small sizes keep it at least ~1.2 px (16) / ~1.5 px (32) wide so it stays visible.
    var frameStroke: CGFloat = 32
    if pixels <= 16 { frameStroke = 1.25 / scale } else if pixels <= 32 { frameStroke = 1.5 / scale }
    let frameInset: CGFloat = 58 + frameStroke / 2   // keep the outer edge where it is
    let frameRect = CGRect(x: 100, y: 100, width: 824, height: 824).insetBy(dx: frameInset, dy: frameInset)
    let frameRadius = 146 - frameStroke / 2
    ctx.addPath(CGPath(roundedRect: frameRect, cornerWidth: frameRadius, cornerHeight: frameRadius, transform: nil))
    ctx.setStrokeColor(frameColor)
    ctx.setLineWidth(frameStroke)
    ctx.strokePath()

    drawHandset(ctx)

    if pixels > 16 {
        ctx.setFillColor(glyphColor)
        ctx.fillEllipse(in: CGRect(x: 716 - 36, y: 716 - 36, width: 72, height: 72))
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <output-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(render(pixels: base * factor), to: outDir.appendingPathComponent(name))
        print("wrote \(name) (\(base * factor) px)")
    }
}
