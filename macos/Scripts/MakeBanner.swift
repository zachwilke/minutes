// Renders the README banner, in light and dark, from the app's own palette.
//
// The picture is the same one the app icon tells: sound on the left — waveform
// bars, the tallest in recording red — becoming lines of text on the right.
// Here it sits on paper next to the wordmark, so a reader meets the mark and
// the name together.
//
// The mark's geometry mirrors MakeIcon.swift deliberately: these are two
// standalone scripts rather than a module, and the icon is the authority. If
// the mark changes there, change it here.
//
// Usage: swift MakeBanner.swift <output-directory>
//        writes banner-light.png and banner-dark.png at 2x.
import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Brand palette (shared/design/palette.md)

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

struct Scheme {
    let paper: CGColor
    let ink: CGColor
    let inkSecondary: CGColor
    let inkTertiary: CGColor
    let hairline: CGColor

    static let light = Scheme(paper: srgb(0xF4F2EE), ink: srgb(0x1C1B19),
                              inkSecondary: srgb(0x6B6660), inkTertiary: srgb(0x9C958B),
                              hairline: srgb(0xE3DFD7))
    static let dark = Scheme(paper: srgb(0x191918), ink: srgb(0xECE9E3),
                             inkSecondary: srgb(0x9E9890), inkTertiary: srgb(0x6E6963),
                             hairline: srgb(0x343230))
}

// The icon's own ground stays warm ink in both schemes, exactly as in the Dock:
// a paper-coloured tile would dissolve into a light README.
let inkLifted = srgb(0x3A3734)
let inkMid = srgb(0x2A2826)
let inkDeep = srgb(0x1C1B19)
let markPaper: UInt32 = 0xF4F2EE
let recording = srgb(0xD8382F)

// MARK: - Shapes

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

// MARK: - The mark

/// The app tile: warm ink squircle, four waveform bars becoming three lines.
func drawTile(in context: CGContext, art: CGRect) {
    let shape = squircle(in: art)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [inkLifted, inkMid, inkDeep] as CFArray,
                              locations: [0, 0.5, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: art.midX, y: art.maxY),
                               end: CGPoint(x: art.midX, y: art.minY), options: [])
    let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [srgb(0xFFFFFF, alpha: 0.08), srgb(0xFFFFFF, alpha: 0)] as CFArray,
                               locations: [0, 1])!
    context.drawLinearGradient(highlight,
                               start: CGPoint(x: art.midX, y: art.maxY),
                               end: CGPoint(x: art.midX, y: art.midY), options: [])
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.addPath(shape)
    context.setStrokeColor(srgb(0x000000, alpha: 0.25))
    context.setLineWidth(max(1, art.width * 0.012))
    context.strokePath()
    context.restoreGState()

    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: art.minX + art.width * fx, y: art.maxY - art.height * fy)
    }
    func length(_ fraction: CGFloat) -> CGFloat { art.width * fraction }
    func fill(_ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.addPath(capsulePath(rect))
        context.fillPath()
    }
    func bar(_ fx: CGFloat, height: CGFloat, width: CGFloat, color: CGColor) {
        let c = point(fx, 0.5)
        fill(CGRect(x: c.x - length(width) / 2, y: c.y - length(height) / 2,
                    width: length(width), height: length(height)), color)
    }
    func line(from x0: CGFloat, to x1: CGFloat, at fy: CGFloat, thickness: CGFloat, color: CGColor) {
        let start = point(x0, fy)
        fill(CGRect(x: start.x, y: start.y - length(thickness) / 2,
                    width: length(x1 - x0), height: length(thickness)), color)
    }

    let weight: CGFloat = 0.045
    bar(0.20, height: 0.18, width: weight, color: srgb(markPaper))
    bar(0.27, height: 0.34, width: weight, color: srgb(markPaper))
    bar(0.34, height: 0.50, width: weight, color: recording)
    bar(0.41, height: 0.26, width: weight, color: srgb(markPaper))
    line(from: 0.51, to: 0.81, at: 0.39, thickness: weight, color: srgb(markPaper))
    line(from: 0.51, to: 0.77, at: 0.50, thickness: weight, color: srgb(markPaper, alpha: 0.80))
    line(from: 0.51, to: 0.66, at: 0.61, thickness: weight, color: srgb(markPaper, alpha: 0.60))
}

// MARK: - Type

/// Document titles are serif in the app; the wordmark follows.
func serif(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
    if let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        .withDesign(.serif) {
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
    return .systemFont(ofSize: size, weight: weight)
}

func draw(_ text: String, font: NSFont, color: CGColor, at origin: CGPoint,
          tracking: CGFloat = 0, in context: CGContext) -> CGSize {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? .black,
        .kern: tracking
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = origin
    CTLineDraw(line, context)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    return CGSize(width: bounds.width, height: bounds.height)
}

// MARK: - Banner

// The canvas is sized to the type rather than guessed at, so the margins stay
// even whatever the strings say. Measured first, drawn second.
let scale: CGFloat = 2
let margin: CGFloat = 64
let tileSide: CGFloat = 148
let gutter: CGFloat = 46

let wordmark = "Minutes"
let tagline = "Meeting notes that never leave your Mac."
let specifics = "ON-DEVICE TRANSCRIPTION  ·  YOUR OWN CLAUDE SUBSCRIPTION  ·  NO API KEY"

let wordmarkFont = serif(72)
let taglineFont = NSFont.systemFont(ofSize: 22, weight: .regular)
let specificsFont = NSFont.systemFont(ofSize: 12, weight: .medium)

func measure(_ text: String, font: NSFont, tracking: CGFloat) -> CGFloat {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font, .kern: tracking]))
    return CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
}

let textX = margin + tileSide + gutter
let contentWidth = max(measure(wordmark, font: wordmarkFont, tracking: -1.2),
                       measure(tagline, font: taglineFont, tracking: 0),
                       measure(specifics, font: specificsFont, tracking: 1.1))
let width = (textX + contentWidth + margin).rounded()
let height = (tileSide + margin * 2).rounded()

func drawBanner(_ scheme: Scheme) -> CGImage? {
    guard let context = CGContext(data: nil,
                                  width: Int(width * scale), height: Int(height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    context.setFillColor(scheme.paper)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let tile = CGRect(x: margin, y: (height - tileSide) / 2, width: tileSide, height: tileSide)
    drawTile(in: context, art: tile)

    // The three lines hang off the tile's top edge rather than its centre, so
    // the wordmark's cap height and the tile's shoulder start together.
    let capTop = tile.maxY - 10
    _ = draw(wordmark, font: wordmarkFont, color: scheme.ink,
             at: CGPoint(x: textX, y: capTop - wordmarkFont.capHeight), tracking: -1.2, in: context)
    _ = draw(tagline, font: taglineFont, color: scheme.inkSecondary,
             at: CGPoint(x: textX + 2, y: capTop - wordmarkFont.capHeight - 36), in: context)

    let ruleY = (capTop - wordmarkFont.capHeight - 58).rounded()
    context.setFillColor(scheme.hairline)
    context.fill(CGRect(x: textX + 2, y: ruleY, width: contentWidth, height: 1))
    _ = draw(specifics, font: specificsFont, color: scheme.inkTertiary,
             at: CGPoint(x: textX + 2, y: ruleY - 22), tracking: 1.1, in: context)

    return context.makeImage()
}

// MARK: - Output

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: MakeBanner.swift <output-directory>\n".data(using: .utf8)!)
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for (name, scheme) in [("banner-light", Scheme.light), ("banner-dark", Scheme.dark)] {
    guard let image = drawBanner(scheme) else {
        FileHandle.standardError.write("error: could not render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: width, height: height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("error: could not encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outputDirectory.appendingPathComponent("\(name).png")
    try data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(Int(width * scale))×\(Int(height * scale)))")
}
