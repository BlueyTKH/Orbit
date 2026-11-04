// Packs licensed AirPods 4 product renders; see AIRPODS_ARTWORK.md.
import AppKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let frames = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appendingPathComponent(".build/airpods4-product/frames")
let output = root.appendingPathComponent("DynamicIsland/Assets.xcassets/AirPodsCaseFourth.imageset/frames.png")
let atlas = CGContext(data: nil, width: 192*8, height: 258*8, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
atlas.interpolationQuality = .high
for frame in 0..<64 {
    let url = frames.appendingPathComponent(String(format: "%02d.png", frame))
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Missing product frame: \(url.path)")
    }
    atlas.draw(image, in: CGRect(x: (frame%8)*192, y: (7-frame/8)*258, width: 192, height: 258))
}
let bitmap = NSBitmapImageRep(cgImage: atlas.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
print("Packed 64 product frames:", output.path)
