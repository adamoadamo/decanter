// Fits the icon in Resources/AppIcon.png (a finished rounded-square icon, e.g. exported from
// Icon Composer) onto the 1024×1024 macOS icon canvas, centred and trimmed to its visible
// pixels. Usage: `swift make-icon.swift AppIcon.png out.png`
import AppKit

let canvas = 1024
// The macOS icon grid: an 824-pixel rounded square in the middle of the canvas. macOS 26 then
// draws it as a proper app icon, without the grey tile it gives any other shape.
let fit = 824.0

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
