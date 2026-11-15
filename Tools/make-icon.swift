import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "icon"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let background = color(0x25D366)
let foreground = color(0xF5F5F7)

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

func polygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let mid = { (a: CGPoint, b: CGPoint) in CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    path.move(to: mid(points[points.count - 1], points[0]))
    for i in points.indices {
        let corner = points[i], next = points[(i + 1) % points.count]
        path.addArc(tangent1End: corner, tangent2End: mid(corner, next), radius: radius)
    }
    path.closeSubpath()
    return path
}

func bubble(_ rect: CGRect, tailOnLeft: Bool) -> [CGPath] {
    let t = rect.height * 0.42
    let body = roundedRect(rect.minX, rect.minY, rect.width, rect.height, min(rect.width, rect.height) * 0.32)
    let tail: [CGPoint] = tailOnLeft
        ? [CGPoint(x: rect.minX + t * 0.2, y: rect.minY + t * 0.6), CGPoint(x: rect.minX - t * 0.2, y: rect.minY - t * 0.32), CGPoint(x: rect.minX + t, y: rect.minY + t * 0.15)]
        : [CGPoint(x: rect.maxX - t * 0.2, y: rect.minY + t * 0.6), CGPoint(x: rect.maxX + t * 0.2, y: rect.minY - t * 0.32), CGPoint(x: rect.maxX - t, y: rect.minY + t * 0.15)]
    return [body, polygon(tail, radius: 2)]
}

func bolt(center: CGPoint, scale: CGFloat) -> CGPath {
    let points: [(CGFloat, CGFloat)] = [(4, 20), (-12, -2), (0, -2), (-4, -20), (12, 2), (0, 2)]
    return polygon(points.map { CGPoint(x: center.x + $0.0 * scale, y: center.y + $0.1 * scale) }, radius: 1.5 * scale)
}

func drawArtwork(_ context: CGContext) {
    let back = CGRect(x: 14, y: 20, width: 46, height: 32)
    let front = CGRect(x: 30, y: 42, width: 56, height: 42)
    let backPaths = bubble(back, tailOnLeft: true)
    let frontPaths = bubble(front, tailOnLeft: false)
    let gap: CGFloat = 4

    context.saveGState()
    context.setAlpha(0.5)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(foreground)
    for path in backPaths { context.addPath(path); context.fillPath() }
    context.setBlendMode(.clear)
    context.setStrokeColor(foreground)
    context.setLineWidth(gap * 2)
    context.setLineJoin(.round)
    for path in frontPaths {
        context.addPath(path); context.fillPath()
        context.addPath(path); context.strokePath()
    }
    context.endTransparencyLayer()
    context.restoreGState()

    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(foreground)
    for path in frontPaths { context.addPath(path); context.fillPath() }
    context.setBlendMode(.clear)
    context.addPath(bolt(center: CGPoint(x: front.midX, y: front.midY), scale: 1.0))
    context.fillPath()
    context.endTransparencyLayer()
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

let body: CGRect
switch mode {
case "full":
    body = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    context.setFillColor(background)
    context.fill(body)
case "logo":
    body = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    context.addPath(CGPath(roundedRect: body, cornerWidth: 230, cornerHeight: 230, transform: nil))
    context.setFillColor(background)
    context.fillPath()
default:
    body = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil))
    context.setFillColor(background)
    context.fillPath()
}

context.translateBy(x: body.minX, y: body.minY)
context.scaleBy(x: body.width / 100, y: body.height / 100)
drawArtwork(context)

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
