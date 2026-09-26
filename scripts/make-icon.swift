// Fits the artwork in Resources/AppIcon.png onto the 1024×1024 macOS icon canvas, centred,
// trimmed to its visible pixels. Usage: `swift make-icon.swift AppIcon.png out.png`
import AppKit

let canvas = 1024
let fit = 1000.0  // The artwork's longer side: it fills the icon, with just enough room for its outline.

let source = NSBitmapImageRep(data: NSImage(contentsOfFile: CommandLine.arguments[1])!.tiffRepresentation!)!
var (minX, minY, maxX, maxY) = (source.pixelsWide, source.pixelsHigh, 0, 0)
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.03 {
        (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
    }
}
let art = source.cgImage!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
let scale = fit / Double(max(art.width, art.height))
let (w, h) = (Double(art.width) * scale, Double(art.height) * scale)

let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.draw(art, in: CGRect(x: (Double(canvas) - w) / 2, y: (Double(canvas) - h) / 2, width: w, height: h))
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
