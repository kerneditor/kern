#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let outputDirectory = repoRoot
    .appendingPathComponent("KernApp", isDirectory: true)
    .appendingPathComponent("Resources", isDirectory: true)
    .appendingPathComponent("Assets.xcassets", isDirectory: true)
    .appendingPathComponent("AppIcon.appiconset", isDirectory: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func point(_ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> CGPoint {
    CGPoint(x: x * scale, y: y * scale)
}

func strokePath(
    in context: CGContext,
    points: [CGPoint],
    width: CGFloat,
    color: CGColor
) {
    guard let first = points.first else { return }
    context.saveGState()
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: first)
    for point in points.dropFirst() {
        context.addLine(to: point)
    }
    context.strokePath()
    context.restoreGState()
}

func makeIcon(size: Int) throws -> NSBitmapImageRep {
    let side = CGFloat(size)
    let scale = side / 1024.0
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: side, height: side)

    guard let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        throw NSError(domain: "KernIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create CGContext"])
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))

    // Match image-coordinate drawing: origin at top-left.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    let margin = 64.0 * scale
    let radius = 210.0 * scale
    let iconRect = CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
    let roundedPath = CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(roundedPath)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(calibratedRed: 0.07, green: 0.82, blue: 0.91, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.05, green: 0.48, blue: 0.96, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.03, green: 0.20, blue: 0.84, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.48, 1.0])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: side * 0.20, y: side * 0.05),
        end: CGPoint(x: side * 0.82, y: side * 0.95),
        options: []
    )

    // Gentle Apple-like highlight: soft cyan lift near top-left, no heavy glow.
    let highlightColors = [
        NSColor(calibratedWhite: 1, alpha: 0.24).cgColor,
        NSColor(calibratedWhite: 1, alpha: 0.00).cgColor,
    ] as CFArray
    let highlight = CGGradient(colorsSpace: colorSpace, colors: highlightColors, locations: [0.0, 1.0])!
    context.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: side * 0.36, y: side * 0.20),
        startRadius: 0,
        endCenter: CGPoint(x: side * 0.36, y: side * 0.20),
        endRadius: side * 0.56,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    // White mark. The < arms meet exactly at the same vertex so there is no visual gap.
    let stemTop = point(330, 286, scale: scale)
    let stemBottom = point(330, 738, scale: scale)
    let vertex = point(520, 512, scale: scale)
    let upper = point(728, 292, scale: scale)
    let lower = point(728, 732, scale: scale)
    let stemWidth = 92.0 * scale
    let armWidth = 84.0 * scale

    // Subtle down-right shadow for depth without blue glow.
    let shadowOffset = 6.0 * scale
    let shadowColor = NSColor(calibratedRed: 0, green: 0.06, blue: 0.24, alpha: 0.22).cgColor
    context.setShadow(offset: CGSize(width: 0, height: shadowOffset), blur: 4.0 * scale, color: shadowColor)
    let white = NSColor(calibratedWhite: 1, alpha: 0.98).cgColor
    strokePath(in: context, points: [stemTop, stemBottom], width: stemWidth, color: white)
    strokePath(in: context, points: [upper, vertex, lower], width: armWidth, color: white)
    context.setShadow(offset: .zero, blur: 0, color: nil)

    return rep
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for size in sizes {
    let rep = try makeIcon(size: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "KernIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(size)x\(size) PNG"])
    }
    try png.write(to: outputDirectory.appendingPathComponent("icon_\(size).png"), options: .atomic)
}
print("Generated Kern app icon PNGs in AppIcon.appiconset")
