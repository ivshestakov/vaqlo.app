import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// Фон окна DMG: мягкий градиент + стрелка от иконки приложения к папке Applications.
// Рисуется в 2× (1320×840) → потом ставим 144 dpi, чтобы окно было 660×420 pt и чётким на retina.
let W = 1320, H = 840
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// фон — тёплый светлый градиент (под жёлтую иконку)
let grad = CGGradient(colorsSpace: cs, colors: [
    c(0.99, 0.98, 0.96), c(0.95, 0.94, 0.93),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: 0, y: 0), options: [])

// стрелка между позициями иконок (в points: app≈165, Applications≈495, y≈205 → ×2)
// иконки 112pt=224px, центры на 330 и 990 px; стрелка в зазоре.
let y = CGFloat(H) - 410   // CG y снизу-вверх; 205pt*2=410 от верха
let x0: CGFloat = 470, x1: CGFloat = 838
ctx.setStrokeColor(c(0.80, 0.78, 0.74))
ctx.setLineCap(.round)
ctx.setLineWidth(14)
ctx.move(to: CGPoint(x: x0, y: y))
ctx.addLine(to: CGPoint(x: x1, y: y))
ctx.strokePath()
// наконечник
ctx.setFillColor(c(0.80, 0.78, 0.74))
ctx.move(to: CGPoint(x: x1 + 26, y: y))
ctx.addLine(to: CGPoint(x: x1 - 18, y: y + 26))
ctx.addLine(to: CGPoint(x: x1 - 18, y: y - 26))
ctx.closePath()
ctx.fillPath()

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
