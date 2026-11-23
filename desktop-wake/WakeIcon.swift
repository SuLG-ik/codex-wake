import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func draw(_ context: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGPath(roundedRect: CGRect(x: 58, y: 58, width: 908, height: 908),
                      cornerWidth: 202, cornerHeight: 202, transform: nil)
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        color(0.06, 0.14, 0.26),
        color(0.15, 0.26, 0.49),
        color(0.30, 0.28, 0.63),
    ] as CFArray, locations: [0, 0.58, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 90, y: 100),
                              end: CGPoint(x: 900, y: 930), options: [])

    let terminal = CGPath(roundedRect: CGRect(x: 194, y: 246, width: 636, height: 532),
                          cornerWidth: 109, cornerHeight: 109, transform: nil)
    context.addPath(terminal)
    context.setFillColor(color(0.02, 0.08, 0.19, 0.72))
    context.fillPath()
    context.addPath(terminal)
    context.setStrokeColor(color(0.67, 0.78, 0.98, 0.72))
    context.setLineWidth(18)
    context.strokePath()

    context.setStrokeColor(color(0.88, 0.93, 1))
    context.setLineWidth(30)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 312, y: 570))
    context.addLine(to: CGPoint(x: 406, y: 492))
    context.addLine(to: CGPoint(x: 312, y: 414))
    context.strokePath()
    context.move(to: CGPoint(x: 434, y: 414))
    context.addLine(to: CGPoint(x: 493, y: 414))
    context.strokePath()

    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: 663, y: 685))
    for point in [CGPoint(x: 515, y: 488), CGPoint(x: 608, y: 488),
                  CGPoint(x: 566, y: 350), CGPoint(x: 732, y: 550),
                  CGPoint(x: 631, y: 550)] {
        bolt.addLine(to: point)
    }
    bolt.closeSubpath()
    context.addPath(bolt)
    context.setFillColor(color(0.42, 0.99, 0.85))
    context.fillPath()
}

for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        draw(context, pixels: pixels)
        let suffix = multiplier == 1 ? "" : "@2x"
        let file = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
