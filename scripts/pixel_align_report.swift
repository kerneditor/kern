#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

struct BBox {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    init() {
        minX = Int.max
        minY = Int.max
        maxX = Int.min
        maxY = Int.min
    }

    mutating func include(x: Int, y: Int) {
        if x < minX { minX = x }
        if y < minY { minY = y }
        if x > maxX { maxX = x }
        if y > maxY { maxY = y }
    }

    var isValid: Bool { minX <= maxX && minY <= maxY }
    var width: Int { max(0, maxX - minX + 1) }
    var height: Int { max(0, maxY - minY + 1) }
    var midX: Double { Double(minX + maxX) / 2.0 }
    var midY: Double { Double(minY + maxY) / 2.0 }
}

struct Component {
    let bbox: BBox
    let area: Int
    let centroidY: Double
}

func usage() -> Never {
    fputs(
        """
pixel_align_report.swift

Compute a per-pixel vertical alignment report for checkbox glyphs vs adjacent text.

Usage:
  scripts/pixel_align_report.swift /path/to/screenshot.png

Notes:
- This is a heuristic analyzer designed for KernTextKit UI/snapshot screenshots.
- It reports deltas in raw image pixels.
""",
        stderr
    )
    exit(2)
}

guard CommandLine.arguments.count >= 2 else { usage() }
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
    fputs("Failed to open image source: \(path)\n", stderr)
    exit(1)
}
guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fputs("Failed to decode image: \(path)\n", stderr)
    exit(1)
}

let width = image.width
let height = image.height

// Normalize to a known pixel format.
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
let colorSpace = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

guard let ctx = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func pixelRGBA(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let idx = y * bytesPerRow + x * bytesPerPixel
    return (pixels[idx], pixels[idx + 1], pixels[idx + 2], pixels[idx + 3])
}

func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
    // sRGB luminance approximation.
    let rf = Double(r) / 255.0
    let gf = Double(g) / 255.0
    let bf = Double(b) / 255.0
    return 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
}

func estimateBackgroundLuma() -> Double {
    // Use a coarse grid median. Most pixels are background; median is robust even with
    // gradients (dark mode) and a few bright UI elements.
    let stepX = max(1, width / 90)
    let stepY = max(1, height / 90)

    var samples: [Double] = []
    samples.reserveCapacity((width / stepX) * (height / stepY))

    for y in stride(from: 0, to: height, by: stepY) {
        for x in stride(from: 0, to: width, by: stepX) {
            let p = pixelRGBA(x: x, y: y)
            // Include fully transparent pixels as background candidates. SnapshotTesting PNGs can
            // encode the window background with alpha=0, and skipping them can make the "median"
            // skew toward text (misclassifying dark mode as light).
            samples.append(luminance(r: p.r, g: p.g, b: p.b))
        }
    }

    guard !samples.isEmpty else { return 1.0 }
    samples.sort()
    return samples[samples.count / 2]
}

let bg = estimateBackgroundLuma()
let isLightBackground = bg > 0.55
let thresh = isLightBackground ? 0.18 : 0.12

func isInk(x: Int, y: Int) -> Bool {
    let p = pixelRGBA(x: x, y: y)
    if p.a < 10 { return false }
    let l = luminance(r: p.r, g: p.g, b: p.b)
    if isLightBackground {
        return (bg - l) > thresh
    } else {
        return (l - bg) > thresh
    }
}

// Scan a left-side region for checkbox-like connected components.
let roiMaxX = min(width, 420)
let roiMaxY = min(height, 700)

let roiW = roiMaxX
let roiH = roiMaxY
var visited = [UInt8](repeating: 0, count: roiW * roiH)

func idx(_ x: Int, _ y: Int) -> Int { y * roiW + x }

func bfsComponent(startX: Int, startY: Int) -> Component {
    var stack: [(Int, Int)] = [(startX, startY)]
    visited[idx(startX, startY)] = 1

    var bbox = BBox()
    var area = 0
    var sumY = 0

    while let (x, y) = stack.popLast() {
        bbox.include(x: x, y: y)
        area += 1
        sumY += y

        // 4-connected.
        let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
        for (nx, ny) in neighbors {
            if nx < 0 || ny < 0 || nx >= roiW || ny >= roiH { continue }
            let vi = idx(nx, ny)
            if visited[vi] != 0 { continue }
            if !isInk(x: nx, y: ny) { continue }
            visited[vi] = 1
            stack.append((nx, ny))
        }
    }
    let centroidY = Double(sumY) / Double(max(1, area))
    return Component(bbox: bbox, area: area, centroidY: centroidY)
}

var components: [Component] = []
components.reserveCapacity(256)

for y in 0..<roiH {
    for x in 0..<roiW {
        if visited[idx(x, y)] != 0 { continue }
        if !isInk(x: x, y: y) { continue }
        let c = bfsComponent(startX: x, startY: y)
        // Ignore tiny specks.
        if c.area < 30 { continue }
        components.append(c)
    }
}

func looksLikeCheckbox(_ c: Component) -> Bool {
    let w = c.bbox.width
    let h = c.bbox.height
    if w < 14 || h < 14 { return false }
    if w > 70 || h > 70 { return false }
    let ratio = Double(w) / Double(h)
    if ratio < 0.6 || ratio > 1.6 { return false }
    let fill = Double(c.area) / Double(max(1, w * h))
    // Checkbox glyphs are mostly outline, so fill ratio is typically low-ish.
    if fill < 0.04 || fill > 0.50 { return false }
    // Prefer components near the left edge.
    if c.bbox.minX > 240 { return false }

    // Hollow-ish center check: inner region should be mostly background.
    // This rejects many letters/numerals that can look "square-ish" at small sizes.
    let inset = max(2, min(w, h) / 5)
    let innerMinX = c.bbox.minX + inset
    let innerMaxX = c.bbox.maxX - inset
    let innerMinY = c.bbox.minY + inset
    let innerMaxY = c.bbox.maxY - inset
    if innerMinX < innerMaxX, innerMinY < innerMaxY {
        var innerInk = 0
        var innerTotal = 0
        for y in innerMinY...innerMaxY {
            for x in innerMinX...innerMaxX {
                innerTotal += 1
                if isInk(x: x, y: y) { innerInk += 1 }
            }
        }
        let innerFill = Double(innerInk) / Double(max(1, innerTotal))
        // Checked checkboxes have a checkmark in the middle, which increases inner ink.
        // Keep this loose enough to accept ☑ but still reject most letters.
        if innerFill > 0.70 { return false }
    }
    return true
}

let rawCheckboxComponents = components.filter(looksLikeCheckbox).sorted { a, b in
    if a.bbox.minY != b.bbox.minY { return a.bbox.minY < b.bbox.minY }
    return a.bbox.minX < b.bbox.minX
}

// Merge nearby checkbox components (checked glyphs often have a disconnected checkmark).
struct CheckboxAccum {
    var bbox: BBox
    var area: Int
    var weightedCentroidYSum: Double

    init(first: Component) {
        bbox = first.bbox
        area = first.area
        weightedCentroidYSum = first.centroidY * Double(first.area)
    }

    mutating func add(_ c: Component) {
        bbox.include(x: c.bbox.minX, y: c.bbox.minY)
        bbox.include(x: c.bbox.maxX, y: c.bbox.maxY)
        weightedCentroidYSum += c.centroidY * Double(c.area)
        area += c.area
    }

    var centroidY: Double { weightedCentroidYSum / Double(max(1, area)) }
}

func bboxesIntersect(_ a: BBox, _ b: BBox, pad: Int) -> Bool {
    let aMinX = a.minX - pad
    let aMaxX = a.maxX + pad
    let aMinY = a.minY - pad
    let aMaxY = a.maxY + pad
    return !(b.maxX < aMinX || b.minX > aMaxX || b.maxY < aMinY || b.minY > aMaxY)
}

var merged: [CheckboxAccum] = []
for c in rawCheckboxComponents {
    var mergedIntoExisting = false
    for i in merged.indices {
        if bboxesIntersect(merged[i].bbox, c.bbox, pad: 6) {
            merged[i].add(c)
            mergedIntoExisting = true
            break
        }
    }
    if !mergedIntoExisting {
        merged.append(CheckboxAccum(first: c))
    }
}

let checkboxComponents: [Component] = merged
    .map { Component(bbox: $0.bbox, area: $0.area, centroidY: $0.centroidY) }
    .sorted { a, b in
        if a.bbox.minY != b.bbox.minY { return a.bbox.minY < b.bbox.minY }
        return a.bbox.minX < b.bbox.minX
    }

if checkboxComponents.isEmpty {
    print("No checkbox-like components found in ROI (image may be cropped differently).")
    exit(0)
}

func textLineMetrics(nextTo checkbox: Component) -> (bbox: BBox, area: Int, centroidY: Double)? {
    // Find the text line's vertical band by probing a narrow strip just after the checkbox.
    // This yields a stable "line box" even when the text glyph shapes differ (or are struck).
    let cb = checkbox.bbox
    let x0 = min(width - 1, cb.maxX + 6)
    let x1 = min(width - 1, x0 + 420)
    if x0 >= x1 { return nil }

    let pad = max(14, Int(Double(cb.height) * 1.25))
    let probeY0 = max(0, cb.minY - pad)
    let probeY1 = min(height - 1, cb.maxY + pad)
    if probeY0 >= probeY1 { return nil }

    let probeX0 = x0
    let probeX1 = min(width - 1, x0 + 22)
    if probeX0 >= probeX1 { return nil }

    // For each row, mark if any ink exists in the probe strip.
    var hasInkRow = [Bool](repeating: false, count: probeY1 - probeY0 + 1)
    for (i, y) in (probeY0...probeY1).enumerated() {
        var any = false
        for x in probeX0...probeX1 {
            if isInk(x: x, y: y) {
                any = true
                break
            }
        }
        hasInkRow[i] = any
    }

    // Build contiguous row segments with ink.
    struct Seg { let y0: Int; let y1: Int }
    var segs: [Seg] = []
    var runStart: Int? = nil
    for (i, v) in hasInkRow.enumerated() {
        if v {
            if runStart == nil { runStart = i }
        } else if let rs = runStart {
            segs.append(Seg(y0: probeY0 + rs, y1: probeY0 + i - 1))
            runStart = nil
        }
    }
    if let rs = runStart {
        segs.append(Seg(y0: probeY0 + rs, y1: probeY1))
    }
    if segs.isEmpty { return nil }

    // Choose the segment that overlaps the checkbox bbox the most.
    func overlap(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Int {
        let lo = max(a0, b0)
        let hi = min(a1, b1)
        return max(0, hi - lo + 1)
    }

    let cbMidY = Int((cb.minY + cb.maxY) / 2)
    var best = segs[0]
    var bestOverlap = overlap(segs[0].y0, segs[0].y1, cb.minY, cb.maxY)
    var bestDist = abs(((segs[0].y0 + segs[0].y1) / 2) - cbMidY)
    for s in segs.dropFirst() {
        let o = overlap(s.y0, s.y1, cb.minY, cb.maxY)
        let d = abs(((s.y0 + s.y1) / 2) - cbMidY)
        if o > bestOverlap || (o == bestOverlap && d < bestDist) {
            best = s
            bestOverlap = o
            bestDist = d
        }
    }

    let lineY0 = max(0, best.y0 - 2)
    let lineY1 = min(height - 1, best.y1 + 2)
    if lineY0 >= lineY1 { return nil }

    var bbox = BBox()
    var area = 0
    var sumY = 0
    for y in lineY0...lineY1 {
        for x in x0...x1 {
            if isInk(x: x, y: y) {
                bbox.include(x: x, y: y)
                area += 1
                sumY += y
            }
        }
    }
    guard bbox.isValid, area > 0 else { return nil }
    let centroidY = Double(sumY) / Double(area)
    return (bbox, area, centroidY)
}

print("Image: \(path)")
print("Size: \(width)x\(height) px")
print(String(format: "Background luma: %.3f (%@)", bg, isLightBackground ? "light" : "dark"))
print("")
print("Checkbox alignment report (pixels):")
print("  deltaY < 0 means checkbox is BELOW the text center; > 0 means checkbox is ABOVE.")

var i = 0
for c in checkboxComponents.prefix(12) {
    i += 1
    let cb = c.bbox
    guard let t = textLineMetrics(nextTo: c) else {
        print("\(i). checkbox bbox=(\(cb.minX),\(cb.minY))..(\(cb.maxX),\(cb.maxY))  text=<not found>")
        continue
    }
    let deltaMidY = t.bbox.midY - cb.midY
    let deltaCentroid = t.centroidY - c.centroidY
    print(String(
        format: "%2d. checkbox bbox=(%d,%d)..(%d,%d) midY=%.1f centroidY=%.1f  text bbox=(%d,%d)..(%d,%d) midY=%.1f centroidY=%.1f  deltaMidY=%.1f px  deltaCentroid=%.1f px",
        i,
        cb.minX, cb.minY, cb.maxX, cb.maxY, cb.midY, c.centroidY,
        t.bbox.minX, t.bbox.minY, t.bbox.maxX, t.bbox.maxY, t.bbox.midY, t.centroidY,
        deltaMidY,
        deltaCentroid
    ))
}
