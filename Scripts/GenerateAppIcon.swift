#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let margin = s * 0.06
    let corner = s * 0.22
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Teal → indigo gradient (clipboard / utility feel)
    let colors = [
        CGColor(srgbRed: 0.12, green: 0.42, blue: 0.52, alpha: 1),
        CGColor(srgbRed: 0.18, green: 0.35, blue: 0.62, alpha: 1),
        CGColor(srgbRed: 0.28, green: 0.22, blue: 0.58, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Top sheen
    if let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }

    ctx.restoreGState()

    // Border
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.addPath(path)
    ctx.strokePath()

    drawClipboard(in: ctx, size: s, bounds: rect)
    return ctx.makeImage()
}

func drawClipboard(in ctx: CGContext, size s: CGFloat, bounds: CGRect) {
    let boardW = s * 0.42
    let boardH = s * 0.52
    let boardX = bounds.midX - boardW / 2
    let boardY = bounds.midY - boardH / 2 - s * 0.02
    let boardRect = CGRect(x: boardX, y: boardY, width: boardW, height: boardH)
    let boardCorner = s * 0.05

    // Board body
    let boardPath = CGPath(
        roundedRect: boardRect,
        cornerWidth: boardCorner,
        cornerHeight: boardCorner,
        transform: nil
    )
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.addPath(boardPath)
    ctx.fillPath()

    // Clip at top
    let clipW = boardW * 0.42
    let clipH = s * 0.08
    let clipRect = CGRect(
        x: bounds.midX - clipW / 2,
        y: boardRect.maxY - clipH * 0.35,
        width: clipW,
        height: clipH
    )
    let clipPath = CGPath(
        roundedRect: clipRect,
        cornerWidth: clipH * 0.3,
        cornerHeight: clipH * 0.3,
        transform: nil
    )
    ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.78, blue: 0.85, alpha: 1))
    ctx.addPath(clipPath)
    ctx.fillPath()

    // Lines on board
    ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.50, blue: 0.62, alpha: 0.55))
    ctx.setLineWidth(max(1.0, s * 0.018))
    ctx.setLineCap(.round)
    let lineInset = boardW * 0.18
    let lineStartY = boardRect.minY + boardH * 0.28
    for i in 0..<3 {
        let y = lineStartY + CGFloat(i) * boardH * 0.16
        let widthFactor: CGFloat = i == 2 ? 0.65 : 1.0
        ctx.move(to: CGPoint(x: boardRect.minX + lineInset, y: y))
        ctx.addLine(to: CGPoint(
            x: boardRect.minX + lineInset + (boardW - lineInset * 2) * widthFactor,
            y: y
        ))
        ctx.strokePath()
    }
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// --- main ---
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// Apple iconutil requires this exact naming inside *.iconset:
//   icon_<pt>x<pt>.png      → 1x (logical point size)
//   icon_<pt>x<pt>@2x.png   → 2x retina (pixel size = 2 * point size)
// The "@2x" suffix is Apple's retina scale marker (not an email address).
// Built with "\u{0040}2x" in source so the scale token stays unambiguous.
// https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html
private let retina = "\u{0040}2x" // → "@2x"

let sizes: [(pixels: Int, filename: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16\(retina).png"),   // 16pt @2x → 32px
    (32, "icon_32x32.png"),
    (64, "icon_32x32\(retina).png"),   // 32pt @2x → 64px
    (128, "icon_128x128.png"),
    (256, "icon_128x128\(retina).png"), // 128pt @2x → 256px
    (256, "icon_256x256.png"),
    (512, "icon_256x256\(retina).png"), // 256pt @2x → 512px
    (512, "icon_512x512.png"),
    (1024, "icon_512x512\(retina).png"), // 512pt @2x → 1024px
]

for entry in sizes {
    if let img = renderIcon(size: entry.pixels) {
        writePNG(img, to: iconset.appendingPathComponent(entry.filename))
    }
}

if let img1024 = renderIcon(size: 1024) {
    writePNG(img1024, to: assets.appendingPathComponent("AppIcon-1024.png"))
}

let icns = assets.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus == 0 {
    print("Wrote \(icns.path)")
} else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
