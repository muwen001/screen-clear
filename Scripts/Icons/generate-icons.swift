#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

enum GeneratorError: LocalizedError {
    case invalidOutput(String)
    case outputExists(String)
    case bitmap(Int)
    case png(Int)
    case pdf
    case iconutil(Int32)
    case injectedFailure

    var errorDescription: String? {
        switch self {
        case .invalidOutput(let path): return "invalid output directory: \(path)"
        case .outputExists(let path): return "refusing to replace existing output: \(path)"
        case .bitmap(let size): return "cannot create \(size)x\(size) bitmap"
        case .png(let size): return "cannot encode \(size)x\(size) PNG"
        case .pdf: return "cannot create menu-bar PDF"
        case .iconutil(let status): return "iconutil failed with status \(status)"
        case .injectedFailure: return "test failure after staging"
        }
    }
}

struct IconVariant {
    let name: String
    let pixels: Int
}

let variants = [
    IconVariant(name: "icon_16x16.png", pixels: 16),
    IconVariant(name: "icon_16x16@2x.png", pixels: 32),
    IconVariant(name: "icon_32x32.png", pixels: 32),
    IconVariant(name: "icon_32x32@2x.png", pixels: 64),
    IconVariant(name: "icon_128x128.png", pixels: 128),
    IconVariant(name: "icon_128x128@2x.png", pixels: 256),
    IconVariant(name: "icon_256x256.png", pixels: 256),
    IconVariant(name: "icon_256x256@2x.png", pixels: 512),
    IconVariant(name: "icon_512x512.png", pixels: 512),
    IconVariant(name: "icon_512x512@2x.png", pixels: 1024),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha).cgColor
}

func sparklePath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let points = [
        CGPoint(x: center.x, y: center.y + outer),
        CGPoint(x: center.x + inner, y: center.y + inner),
        CGPoint(x: center.x + outer, y: center.y),
        CGPoint(x: center.x + inner, y: center.y - inner),
        CGPoint(x: center.x, y: center.y - outer),
        CGPoint(x: center.x - inner, y: center.y - inner),
        CGPoint(x: center.x - outer, y: center.y),
        CGPoint(x: center.x - inner, y: center.y + inner),
    ]
    path.move(to: points[0])
    points.dropFirst().forEach { path.addLine(to: $0) }
    path.closeSubpath()
    return path
}

let appIconArtworkScale: CGFloat = 0.90

func drawCenteredAppArtwork(
    in context: CGContext,
    canvas: CGFloat,
    draw: () -> Void
) {
    context.saveGState()
    context.translateBy(x: canvas / 2, y: canvas / 2)
    context.scaleBy(x: appIconArtworkScale, y: appIconArtworkScale)
    context.translateBy(x: -canvas / 2, y: -canvas / 2)
    draw()
    context.restoreGState()
}

func drawCompactAppIcon(in context: CGContext) {
    let background = CGPath(
        roundedRect: CGRect(x: 0.625, y: 0.625, width: 14.75, height: 14.75),
        cornerWidth: 3.625,
        cornerHeight: 3.625,
        transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.086, 0.467, 1), color(0.318, 0.275, 0.898)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 2, y: 14.75),
        end: CGPoint(x: 14.125, y: 1.125),
        options: []
    )
    context.restoreGState()

    let screen = CGPath(
        roundedRect: CGRect(x: 2, y: 5, width: 9, height: 7),
        cornerWidth: 1,
        cornerHeight: 1,
        transform: nil
    )
    context.addPath(screen)
    context.setFillColor(color(1, 1, 1))
    context.fillPath()

    let screenInterior = CGPath(
        roundedRect: CGRect(x: 3, y: 6, width: 7, height: 5),
        cornerWidth: 0.5,
        cornerHeight: 0.5,
        transform: nil
    )
    context.addPath(screenInterior)
    context.setFillColor(color(0.35, 0.47, 0.93))
    context.fillPath()

    context.setFillColor(color(1, 1, 1))
    context.fill(CGRect(x: 6, y: 3, width: 2, height: 3))
    context.addPath(CGPath(
        roundedRect: CGRect(x: 4, y: 2, width: 6, height: 2),
        cornerWidth: 1,
        cornerHeight: 1,
        transform: nil
    ))
    context.fillPath()

    context.addPath(sparklePath(center: CGPoint(x: 12.7, y: 12.7), outer: 2.35, inner: 1))
    context.setFillColor(color(1, 1, 1))
    context.fillPath()
    context.addPath(sparklePath(center: CGPoint(x: 12.7, y: 12.7), outer: 1.55, inner: 0.65))
    context.setFillColor(color(0.73, 0.96, 1))
    context.fillPath()
}

func drawAppIcon(in context: CGContext, pixels: Int) {
    let lineWidth: CGFloat = pixels <= 32 ? 7 : 6
    let background = CGPath(
        roundedRect: CGRect(x: 5, y: 5, width: 118, height: 118),
        cornerWidth: 29,
        cornerHeight: 29,
        transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.086, 0.467, 1), color(0.318, 0.275, 0.898)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 16, y: 118),
        end: CGPoint(x: 113, y: 9),
        options: []
    )
    context.restoreGState()

    let screen = CGPath(
        roundedRect: CGRect(x: 26, y: 40, width: 76, height: 57),
        cornerWidth: 7.5,
        cornerHeight: 7.5,
        transform: nil
    )
    context.addPath(screen)
    context.setFillColor(color(1, 1, 1, 0.20))
    context.fillPath()
    context.addPath(screen)
    context.setStrokeColor(color(1, 1, 1, 0.96))
    context.setLineWidth(lineWidth)
    context.strokePath()

    context.setLineCap(.round)
    context.setLineWidth(lineWidth)
    context.move(to: CGPoint(x: 64, y: 40))
    context.addLine(to: CGPoint(x: 64, y: 27))
    context.move(to: CGPoint(x: 52, y: 27))
    context.addLine(to: CGPoint(x: 76, y: 27))
    context.strokePath()

    context.addPath(sparklePath(center: CGPoint(x: 87, y: 96), outer: 13, inner: 4.8))
    context.setFillColor(color(0.73, 0.96, 1))
    context.fillPath()
    context.addPath(sparklePath(center: CGPoint(x: 87, y: 96), outer: 13, inner: 4.8))
    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(2)
    context.setLineJoin(.round)
    context.strokePath()
}

func pngData(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw GeneratorError.bitmap(pixels)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    if pixels == 16 {
        drawCompactAppIcon(in: graphics.cgContext)
    } else {
        graphics.cgContext.scaleBy(x: CGFloat(pixels) / 128, y: CGFloat(pixels) / 128)
        drawCenteredAppArtwork(in: graphics.cgContext, canvas: 128) {
            drawAppIcon(in: graphics.cgContext, pixels: pixels)
        }
    }
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw GeneratorError.png(pixels)
    }
    return data
}

func writeMenuBarPDF(to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw GeneratorError.pdf
    }
    context.beginPDFPage(nil)
    context.setStrokeColor(color(0, 0, 0))
    context.setFillColor(color(0, 0, 0))
    context.setLineWidth(1.55)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(CGPath(
        roundedRect: CGRect(x: 1.25, y: 5.5, width: 11.5, height: 8.25),
        cornerWidth: 1.6,
        cornerHeight: 1.6,
        transform: nil
    ))
    context.strokePath()
    context.move(to: CGPoint(x: 7, y: 5.5))
    context.addLine(to: CGPoint(x: 7, y: 3))
    context.move(to: CGPoint(x: 4.6, y: 3))
    context.addLine(to: CGPoint(x: 9.4, y: 3))
    context.strokePath()
    context.addPath(sparklePath(center: CGPoint(x: 14.7, y: 14.2), outer: 3.2, inner: 1.15))
    context.fillPath()
    context.endPDFPage()
    context.closePDF()
}

func runIconutil(iconset: URL, output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GeneratorError.iconutil(process.terminationStatus)
    }
}

func exists(_ url: URL, manager: FileManager) -> Bool {
    (try? manager.attributesOfItem(atPath: url.path)) != nil
}

func publish(_ stagedTargets: [(staged: URL, destination: URL)], manager: FileManager) throws {
    var published: [URL] = []
    do {
        for target in stagedTargets {
            guard !exists(target.destination, manager: manager) else {
                throw GeneratorError.outputExists(target.destination.path)
            }
            try manager.moveItem(at: target.staged, to: target.destination)
            published.append(target.destination)
        }
    } catch {
        let publishError = error
        do {
            for target in published.reversed() {
                try manager.removeItem(at: target)
            }
        } catch {
            throw error
        }
        throw publishError
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icons.swift OUTPUT_DIRECTORY\n", stderr)
    exit(64)
}

do {
    let manager = FileManager.default
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let values = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw GeneratorError.invalidOutput(output.path)
    }
    let iconset = output.appendingPathComponent("ScreenClear.iconset", isDirectory: true)
    let icns = output.appendingPathComponent("ScreenClear.icns")
    let menuPDF = output.appendingPathComponent("MenuBarIcon.pdf")
    for target in [iconset, icns, menuPDF] where exists(target, manager: manager) {
        throw GeneratorError.outputExists(target.path)
    }
    let staging = output.appendingPathComponent(
        ".screenclear-icon-staging-\(UUID().uuidString)",
        isDirectory: true
    )
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer {
        try? manager.removeItem(at: staging)
    }
    let stagedIconset = staging.appendingPathComponent("ScreenClear.iconset", isDirectory: true)
    let stagedICNS = staging.appendingPathComponent("ScreenClear.icns")
    let stagedMenuPDF = staging.appendingPathComponent("MenuBarIcon.pdf")
    try manager.createDirectory(at: stagedIconset, withIntermediateDirectories: false)
    for variant in variants {
        let imageURL = stagedIconset.appendingPathComponent(variant.name)
        try pngData(pixels: variant.pixels).write(
            to: imageURL,
            options: .withoutOverwriting
        )
        let writtenData = try Data(contentsOf: imageURL)
        guard let representation = NSBitmapImageRep(data: writtenData),
              representation.pixelsWide == variant.pixels,
              representation.pixelsHigh == variant.pixels else {
            throw GeneratorError.png(variant.pixels)
        }
    }
    try writeMenuBarPDF(to: stagedMenuPDF)
    guard let menuImage = NSImage(contentsOf: stagedMenuPDF),
          menuImage.size.width > 0,
          menuImage.size.height > 0 else {
        throw GeneratorError.pdf
    }
    try runIconutil(iconset: stagedIconset, output: stagedICNS)
    guard manager.fileExists(atPath: stagedICNS.path), manager.fileExists(atPath: stagedMenuPDF.path) else {
        throw GeneratorError.invalidOutput(output.path)
    }
    if ProcessInfo.processInfo.environment["SCREENCLEAR_ICON_TEST_FAIL_AFTER_STAGING"] == "1" {
        throw GeneratorError.injectedFailure
    }
    try publish([
        (staged: stagedIconset, destination: iconset),
        (staged: stagedICNS, destination: icns),
        (staged: stagedMenuPDF, destination: menuPDF),
    ], manager: manager)
} catch {
    fputs("generate-icons: \(error.localizedDescription)\n", stderr)
    exit(1)
}
