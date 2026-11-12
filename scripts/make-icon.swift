#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye
// Draws the SIP Phone app icon and writes the full macOS AppIcon set.
//
//   swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Deterministic: plain CoreGraphics, sRGB, no fonts and no system glyphs. The handset is our own vector
// drawing (SF Symbols must not be used in app icons). Every size is rendered natively at its pixel size;
// at 32 px and below the frame stroke and the handset grip are thickened, and at 16 px the dot is dropped
// (it would only be a smudge next to the handset).
//
// Layout on the 1024 canvas (y from the top), same family as the Dossiary icon:
//   body   rounded square 100…924, radius 185, #1B2426, soft drop shadow below
//   frame  rounded-square outline, centre line inset 74 (outer edge inset 58), stroke 32, #388B6C
//   glyph  phone handset, #4FE0A6, 390 px, slightly up-left of centre
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

// MARK: - Handset
//
// Built in a local frame: the handset lies along the x axis (earpiece at -x, mouthpiece at +x), its back
// bulges towards +y and the cups face -y. The outline is a band swept along an arc whose width depends only
// on |angle|, so the shape is exactly symmetric. A morphological opening rounds the cup corners and a closing
// (grow by r, shrink by r) rounds every inner joint, so there are no notches or corners. The finished path is scaled to `handsetSize`, rotated 45° (earpiece top-left, mouthpiece bottom
// right, back towards the bottom left) and centred at `handsetCentre`.

let handsetSize: CGFloat = 390               // larger side of the rotated bounding box, 1024 units
let handsetCentre = CGPoint(x: 500, y: 470)  // bounding-box centre: slightly up-left, leaves room for the dot

/// Rounds the concave corners of `path` with radius `r` (dilate, then erode).
func closing(_ path: CGPath, _ r: CGFloat) -> CGPath {
    let grown = path.union(path.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 10))
    return grown.subtracting(grown.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 10))
}

/// Rounds the convex corners of `path` with radius `r` (erode, then dilate). Removes parts thinner than 2r.
func opening(_ path: CGPath, _ r: CGFloat) -> CGPath {
    let shrunk = path.subtracting(path.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 10))
    return shrunk.union(shrunk.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 10))
}

func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// A band swept along the arc of radius R (local frame, φ in -φ0…φ0, symmetric because the offset functions
/// only see |φ|). `back(|φ|)` is the offset towards the back (+radius), `face(|φ|)` towards the face. The ends
/// are cut along the radius, i.e. square to the arc.
func sweptBand(radius R: CGFloat, halfAngle phi0: CGFloat, back: (CGFloat) -> CGFloat,
               face: (CGFloat) -> CGFloat) -> CGPath {
    let steps = 240
    let path = CGMutablePath()
    func pt(_ phi: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: r * sin(phi), y: r * cos(phi)) }
    for i in 0...steps {
        let phi = -phi0 + 2 * phi0 * CGFloat(i) / CGFloat(steps)
        let p = pt(phi, R + back(abs(phi)))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    for i in stride(from: steps, through: 0, by: -1) {
        let phi = -phi0 + 2 * phi0 * CGFloat(i) / CGFloat(steps)
        path.addLine(to: pt(phi, R - face(abs(phi))))
    }
    path.closeSubpath()
    return path
}

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// Classic handset: wide cups (thickness `cup`, flaring a little more towards their ends) standing out
/// towards the face, on a slim (~45 %), long, gentle grip; the back is one clean arc. `minWidth` is the
/// smallest grip width (1024 units) that still renders as a solid line at the pixel size being drawn.
func handsetLocal(minWidth: CGFloat) -> CGPath {
    let R: CGFloat = 255, phi0 = deg(47)
    let cup: CGFloat = 120
    let grip = max(54, minWidth)
    let band = sweptBand(radius: R, halfAngle: phi0, back: { _ in grip / 2 },
                         face: { grip / 2 + (cup - grip) * smoothstep(deg(24), deg(33), $0)
                             + 12 * smoothstep(deg(33), deg(47), $0) })
    // Round the cup corners (opening), then put back the slim grip that the opening would thin out.
    let core = sweptBand(radius: R, halfAngle: deg(36), back: { _ in grip / 2 }, face: { _ in grip / 2 })
    return closing(opening(band, 32).union(core), 28)
}

func drawHandset(_ ctx: CGContext, pixels: Int) {
    let minWidth = pixels <= 32 ? 1.3 * 1024 / CGFloat(pixels) : 0
    let local = handsetLocal(minWidth: minWidth)
    var rot = CGAffineTransform(rotationAngle: .pi / 4)
    let rotated = local.copy(using: &rot)!
    let box = rotated.boundingBoxOfPath
    let k = handsetSize / max(box.width, box.height)
    var place = CGAffineTransform(translationX: handsetCentre.x, y: handsetCentre.y)
        .scaledBy(x: k, y: k).translatedBy(x: -box.midX, y: -box.midY)
    ctx.addPath(rotated.copy(using: &place)!)
    ctx.setFillColor(glyphColor)
    ctx.fillPath()
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

    drawHandset(ctx, pixels: pixels)

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
