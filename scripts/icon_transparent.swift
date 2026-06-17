import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// Делает внешний белый фон прозрачным (заливка от 4 углов), не трогая светлые
// области внутри жёлтого сквиркла. На выходе квадратный PNG 1024 с альфой.
let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: icon_transparent <in.png> <out.png>\n", stderr); exit(1) }

guard let src = NSImage(contentsOfFile: args[1]),
      let tiff = src.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cg = rep.cgImage else { fputs("can't read image\n", stderr); exit(1) }

let w = cg.width, h = cg.height
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let bytesPerRow = w * 4
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

func isWhite(_ i: Int) -> Bool {
    pixels[i] >= 244 && pixels[i+1] >= 244 && pixels[i+2] >= 244 && pixels[i+3] >= 250
}

// BFS-заливка от углов: прозрачным становится только связный внешний белый.
var stack: [Int] = []
var visited = [Bool](repeating: false, count: w * h)
for (x, y) in [(0, 0), (w-1, 0), (0, h-1), (w-1, h-1)] {
    stack.append(y * w + x)
}
while let p = stack.popLast() {
    if visited[p] { continue }
    visited[p] = true
    let i = p * 4
    guard isWhite(i) else { continue }
    pixels[i+3] = 0  // прозрачный
    let x = p % w, y = p / w
    if x > 0 { stack.append(p - 1) }
    if x < w-1 { stack.append(p + 1) }
    if y > 0 { stack.append(p - w) }
    if y < h-1 { stack.append(p + w) }
}

guard let out = ctx.makeImage() else { fputs("makeImage failed\n", stderr); exit(1) }
let url = URL(fileURLWithPath: args[2])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("wrote \(args[2]) (\(w)x\(h), outer white → transparent)")
