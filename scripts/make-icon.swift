import AppKit

let size: CGFloat = 1024
let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
let background = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).cgColor

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(background)
ctx.fillPath()
ctx.restoreGState()

let scale: CGFloat = 3.3
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: 512 + (x - 231) * scale, y: 500 - (y - 175) * scale)
}

func bubble(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat, radius: CGFloat, tailStart: CGFloat, tailEnd: CGFloat, tip: CGPoint) -> CGPath {
    let path = CGMutablePath()
    let r = radius * scale
    path.move(to: p(left + radius, top))
    path.addArc(tangent1End: p(right, top), tangent2End: p(right, bottom), radius: r)
    path.addArc(tangent1End: p(right, bottom), tangent2End: p(left, bottom), radius: r)
    path.addLine(to: p(tailEnd, bottom))
    path.addLine(to: p(tip.x, tip.y))
    path.addLine(to: p(tailStart, bottom))
    path.addArc(tangent1End: p(left, bottom), tangent2End: p(left, top), radius: r)
    path.addArc(tangent1End: p(left, top), tangent2End: p(right, top), radius: r)
    path.closeSubpath()
    return path
}

let green = NSColor(srgbRed: 0x21 / 255, green: 0xC0 / 255, blue: 0x63 / 255, alpha: 1).cgColor

func fillGreen(_ path: CGPath) {
    ctx.addPath(path)
    ctx.setFillColor(green)
    ctx.fillPath()
}

let back = bubble(left: 142, top: 104, right: 278, bottom: 210, radius: 28, tailStart: 172, tailEnd: 190, tip: CGPoint(x: 174, y: 229))
let front = bubble(left: 207, top: 136, right: 320, bottom: 226, radius: 24, tailStart: 262, tailEnd: 282, tip: CGPoint(x: 282, y: 243))

fillGreen(back)

ctx.saveGState()
ctx.addPath(front)
ctx.setStrokeColor(background)
ctx.setLineWidth(6 * scale * 2)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

fillGreen(front)

ctx.setStrokeColor(background)
ctx.setLineWidth(9 * scale)
ctx.setLineCap(.round)
ctx.move(to: p(240, 166))
ctx.addLine(to: p(288, 166))
ctx.move(to: p(240, 190))
ctx.addLine(to: p(276, 190))
ctx.strokePath()

let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
