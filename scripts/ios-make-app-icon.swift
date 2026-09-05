// Draws RemoteAI's app icon.
//
// The icon is generated rather than hand-drawn so it can be regenerated at any
// size and reviewed as code. The mark: a terminal caret and cursor — the CLI
// this app drives — inside a rounded field, with a signal arc above it for the
// "remote" half.
//
//     swift scripts/ios-make-app-icon.swift <out.png> [size]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ios-make-app-icon <out.png> [size]\n".utf8))
    exit(2)
}
let size = arguments.count >= 3 ? (Int(arguments[2]) ?? 1024) : 1024
let side = CGFloat(size)

guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// A deep slate field: the icon sits next to terminal tools, not toys.
let top = CGColor(red: 0.13, green: 0.16, blue: 0.23, alpha: 1)
let bottom = CGColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [top, bottom] as CFArray,
    locations: [0, 1]
)!
// Full bleed: iOS applies its own mask, so the art must reach every edge.
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: []
)

let unit = side / 1024

// Signal arcs, centred above the caret.
let arcCentre = CGPoint(x: side / 2, y: side * 0.485)
context.setLineCap(.round)
for (index, radius) in [215.0, 320.0].enumerated() {
    context.setStrokeColor(
        CGColor(red: 0.36, green: 0.71, blue: 0.98, alpha: index == 0 ? 0.95 : 0.55)
    )
    context.setLineWidth(38 * unit)
    context.addArc(
        center: arcCentre, radius: CGFloat(radius) * unit,
        startAngle: .pi * 0.18, endAngle: .pi * 0.82, clockwise: false
    )
    context.strokePath()
}

// The caret: >_
context.setStrokeColor(CGColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1))
context.setLineWidth(58 * unit)
context.setLineJoin(.round)
context.move(to: CGPoint(x: side * 0.305, y: side * 0.485))
context.addLine(to: CGPoint(x: side * 0.475, y: side * 0.350))
context.addLine(to: CGPoint(x: side * 0.305, y: side * 0.215))
context.strokePath()

// The cursor bar beside it.
context.setFillColor(CGColor(red: 0.36, green: 0.71, blue: 0.98, alpha: 1))
let bar = CGRect(x: side * 0.555, y: side * 0.210, width: side * 0.175, height: 58 * unit)
context.addPath(CGPath(roundedRect: bar, cornerWidth: 29 * unit, cornerHeight: 29 * unit, transform: nil))
context.fillPath()

guard let image = context.makeImage() else { exit(1) }
let out = URL(fileURLWithPath: arguments[1])
guard let destination = CGImageDestinationCreateWithURL(
    out as CFURL, UTType.png.identifier as CFString, 1, nil
) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("wrote \(out.path) (\(size)x\(size))")
