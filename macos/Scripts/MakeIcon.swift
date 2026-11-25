// Generates the Minutes app icon at every size macOS asks for.
//
// The mark is the app's whole job in one picture: sound on the left — four
// waveform bars, the tallest in recording red — becoming words on the right,
// three lines of text. Paper on warm ink, the app's own palette (UI/Theme.swift);
// dark rather than paper-coloured so the icon keeps its shape in a light Dock.
//
// Every size is rendered natively rather than scaled down from one large PNG.
// Small sizes also get their own drawing, with fewer, thicker elements snapped
// to whole pixels: four bars and three lines a pixel wide each are a grey smear
// at 16 px, where one red bar and two lines still read.
//
// Usage: makeicon <output-directory>   (writes AppIcon.iconset/*.png + preview.png)
import AppKit
import CoreGraphics
import Foundation

// MARK: - Brand palette

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let inkLifted = srgb(0x3A3734)    // top of the squircle
let inkMid    = srgb(0x2A2826)
let ink       = srgb(0x1C1B19)    // Palette.ink, light mode
let paper     = 0xF4F2EE as UInt32 // Palette.paper
let recording = srgb(0xD8382F)    // Palette.recording, light mode

// MARK: - Shape helpers

/// Apple's icon silhouette is a squircle — a superellipse, not a rounded
/// rectangle. The difference is visible at large sizes next to other app icons.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 240
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let power = 2 / exponent
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), power)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), power)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func capsulePath(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect,
           cornerWidth: min(rect.width, rect.height) / 2,
           cornerHeight: min(rect.width, rect.height) / 2,
           transform: nil)
}

// MARK: - Icon drawing

func drawIcon(size pixels: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let side = CGFloat(pixels)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS leaves the outer ~10% as breathing room and shadow space.
    let inset = side * 0.0977
    let art = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let shape = squircle(in: art)

    // --- Background: warm ink, lifted at the top ---
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [inkLifted, inkMid, ink] as CFArray,
                              locations: [0, 0.5, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: art.midX, y: art.maxY),
                               end: CGPoint(x: art.midX, y: art.minY),
                               options: [])
    if pixels >= 128 {
        // A soft highlight across the top gives the flat ink some dimension.
        let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   colors: [srgb(0xFFFFFF, alpha: 0.08),
                                            srgb(0xFFFFFF, alpha: 0)] as CFArray,
                                   locations: [0, 1])!
        context.drawLinearGradient(highlight,
                                   start: CGPoint(x: art.midX, y: art.maxY),
                                   end: CGPoint(x: art.midX, y: art.midY),
                                   options: [])
    }
    context.restoreGState()

    // Inner hairline, so the icon holds an edge on a dark background too.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.addPath(shape)
    context.setStrokeColor(srgb(0x000000, alpha: 0.25))
    context.setLineWidth(max(1, side * 0.012))
    context.strokePath()
    context.restoreGState()

    // --- The mark ---
    // Geometry is in top-down fractions of the art box, which is how it was
    // designed; `point` flips into CoreGraphics' bottom-up space.
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: art.minX + art.width * fx, y: art.maxY - art.height * fy)
    }
    func length(_ fraction: CGFloat) -> CGFloat { art.width * fraction }
    // Under 128 px, edges land on whole pixels; a bar straddling two pixel
    // columns renders as two half-grey ones.
    let snap = pixels < 128
    // The size is rounded first and the position second; rounding both edges
    // independently gave bars of equal design width different pixel widths.
    func snapped(_ rect: CGRect) -> CGRect {
        guard snap else { return rect }
        let width = max(1, rect.width.rounded()), height = max(1, rect.height.rounded())
        return CGRect(x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(),
                      width: width, height: height)
    }
    func fill(_ rect: CGRect, _ color: CGColor) {
        let r = snapped(rect)
        context.setFillColor(color)
        context.addPath(capsulePath(r))
        context.fillPath()
    }
    /// A vertical waveform bar centred on (fx, 0.5).
    func bar(_ fx: CGFloat, height: CGFloat, width: CGFloat, color: CGColor) {
        let c = point(fx, 0.5)
        fill(CGRect(x: c.x - length(width) / 2, y: c.y - length(height) / 2,
                    width: length(width), height: length(height)), color)
    }
    /// A line of text from x0 to x1, centred on fy.
    func line(from x0: CGFloat, to x1: CGFloat, at fy: CGFloat, thickness: CGFloat, color: CGColor) {
        let start = point(x0, fy)
        fill(CGRect(x: start.x, y: start.y - length(thickness) / 2,
                    width: length(x1 - x0), height: length(thickness)), color)
    }

    switch pixels {
    case 128...:
        // Sound: four bars, the tallest red — this is being recorded.
        let weight: CGFloat = 0.045
        bar(0.20, height: 0.18, width: weight, color: srgb(paper))
        bar(0.27, height: 0.34, width: weight, color: srgb(paper))
        bar(0.34, height: 0.50, width: weight, color: recording)
        bar(0.41, height: 0.26, width: weight, color: srgb(paper))
        // Words: three lines, fading as a paragraph does.
        line(from: 0.51, to: 0.81, at: 0.39, thickness: weight, color: srgb(paper))
        line(from: 0.51, to: 0.77, at: 0.50, thickness: weight, color: srgb(paper, alpha: 0.80))
        line(from: 0.51, to: 0.66, at: 0.61, thickness: weight, color: srgb(paper, alpha: 0.60))
    case 24..<128:
        // Three bars and two lines, heavier.
        let weight: CGFloat = 0.075
        bar(0.24, height: 0.30, width: weight, color: srgb(paper))
        bar(0.36, height: 0.52, width: weight, color: recording)
        bar(0.48, height: 0.22, width: weight, color: srgb(paper))
        line(from: 0.58, to: 0.81, at: 0.40, thickness: weight, color: srgb(paper))
        line(from: 0.58, to: 0.73, at: 0.60, thickness: weight, color: srgb(paper, alpha: 0.75))
    default:
        // 16 px: the red bar and two lines are all that survive.
        let weight: CGFloat = 0.13
        bar(0.30, height: 0.62, width: weight, color: recording)
        line(from: 0.50, to: 0.80, at: 0.36, thickness: weight, color: srgb(paper))
        line(from: 0.50, to: 0.70, at: 0.64, thickness: weight, color: srgb(paper, alpha: 0.8))
    }

    return context.makeImage()
}

// MARK: - Output

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(_ image: CGImage, to url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MakeIcon", code: 1)
    }
    try data.write(to: url)
}

// (pixel size, iconset filename)
let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]

for (pixels, name) in variants {
    guard let image = drawIcon(size: pixels) else {
        FileHandle.standardError.write(Data("failed at \(pixels)px\n".utf8))
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent("\(name).png"))
}

// A standalone preview, handy for dropping into a document or a chat.
if let preview = drawIcon(size: 1024) {
    try write(preview, to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("preview.png"))
}

print("wrote \(variants.count) icon sizes to \(iconset.path)")
