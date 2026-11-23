#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

// Generates a multi-resolution Apple .icns file directly using CoreGraphics + ImageIO
// (headless, display-scale independent, no iconutil/WindowServer dependency).
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output.icns>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

func renderPNG(size: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    let s = CGFloat(size)

    // macOS rounded squircle background
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225
    let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Deep slate gradient
    let colors = [
        CGColor(colorSpace: colorSpace, components: [0.07, 0.11, 0.16, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.04, 0.06, 0.10, 1.0])!
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }

    // Subtle emerald radial glow
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [0.10, 0.85, 0.45, 0.28])!,
        CGColor(colorSpace: colorSpace, components: [0.10, 0.85, 0.45, 0.0])!
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            radial,
            startCenter: CGPoint(x: s * 0.5, y: s * 0.55),
            startRadius: 0,
            endCenter: CGPoint(x: s * 0.5, y: s * 0.55),
            endRadius: s * 0.48,
            options: []
        )
    }

    // Subtle grid lines
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.06])!)
    ctx.setLineWidth(max(1, s * 0.004))
    for i in 1...4 {
        let y = rect.minY + rect.height * CGFloat(i) / 5.0
        ctx.move(to: CGPoint(x: rect.minX, y: y))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
    }
    ctx.strokePath()

    // 4 multi-GPU vertical meter bars
    let barHeights: [CGFloat] = [0.68, 0.90, 0.42, 0.78]
    let barColors: [CGColor] = [
        CGColor(colorSpace: colorSpace, components: [0.20, 0.88, 0.48, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.15, 0.76, 0.96, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.20, 0.88, 0.48, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.46, 0.58, 1.00, 1.0])!
    ]

    let plotInsetX = rect.minX + rect.width * 0.17
    let plotWidth = rect.width * 0.66
    let plotBottom = rect.minY + rect.height * 0.20
    let plotMaxHeight = rect.height * 0.56
    let gap = plotWidth * 0.08
    let barWidth = (plotWidth - gap * CGFloat(barHeights.count - 1)) / CGFloat(barHeights.count)

    for (idx, frac) in barHeights.enumerated() {
        let x = plotInsetX + CGFloat(idx) * (barWidth + gap)

        let trackRect = CGRect(x: x, y: plotBottom, width: barWidth, height: plotMaxHeight)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: barWidth * 0.28, cornerHeight: barWidth * 0.28, transform: nil)
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.09])!)
        ctx.addPath(trackPath)
        ctx.fillPath()

        let h = plotMaxHeight * frac
        let fillRect = CGRect(x: x, y: plotBottom, width: barWidth, height: h)
        let fillPath = CGPath(roundedRect: fillRect, cornerWidth: barWidth * 0.28, cornerHeight: barWidth * 0.28, transform: nil)
        ctx.setFillColor(barColors[idx])
        ctx.addPath(fillPath)
        ctx.fillPath()
    }

    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.18])!)
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.addPath(bgPath)
    ctx.strokePath()

    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// Standard PNG-backed Apple ICNS chunk types (macOS 10.7+)
let icnsEntries: [(String, Int)] = [
    ("icp4", 16),   // 16x16
    ("ic11", 32),   // 16x16@2x
    ("icp5", 32),   // 32x32
    ("ic12", 64),   // 32x32@2x
    ("ic07", 128),  // 128x128
    ("ic13", 256),  // 128x128@2x
    ("ic08", 256),  // 256x256
    ("ic14", 512),  // 256x256@2x
    ("ic09", 512),  // 512x512
    ("ic10", 1024)  // 512x512@2x
]

var pngCache: [Int: Data] = [:]
var body = Data()

for (chunkType, px) in icnsEntries {
    let pngData: Data
    if let cached = pngCache[px] {
        pngData = cached
    } else {
        guard let rendered = renderPNG(size: px) else {
            fputs("Failed to render \(px)x\(px) icon\n", stderr)
            exit(1)
        }
        pngCache[px] = rendered
        pngData = rendered
    }

    let chunkLength = UInt32(8 + pngData.count).bigEndian
    body.append(contentsOf: chunkType.utf8)
    withUnsafeBytes(of: chunkLength) { body.append(contentsOf: $0) }
    body.append(pngData)
}

var icns = Data()
let totalLength = UInt32(8 + body.count).bigEndian
icns.append(contentsOf: "icns".utf8)
withUnsafeBytes(of: totalLength) { icns.append(contentsOf: $0) }
icns.append(body)

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try icns.write(to: outputURL)
