import SwiftUI
import AppKit

enum Palette {
    static let accent = Color(red: 0x21 / 255, green: 0xC0 / 255, blue: 0x63 / 255)
    static let accentText = Color(red: 0.84, green: 0.98, blue: 0.86)
    static let outgoingLight = Color(red: 0.86, green: 0.97, blue: 0.84)
    static let outgoingDark = Color(red: 19 / 255, green: 77 / 255, blue: 56 / 255)
    static let incomingLight = Color.white
    static let incomingDark = Color(red: 35 / 255, green: 38 / 255, blue: 38 / 255)
    static let wallpaperLight = Color(red: 0.94, green: 0.92, blue: 0.89)
    static let wallpaperDark = Color(white: 0.05)
    static let backgroundNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.07, alpha: 1) : .windowBackgroundColor
    }
    static let background = Color(nsColor: backgroundNS)
    static let bar = dynamic(dark: NSColor(white: 0.1, alpha: 1), light: .windowBackgroundColor)
    static let readTick = Color(red: 0.2, green: 0.6, blue: 0.95)
    static let linkNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x21 / 255, green: 0xC0 / 255, blue: 0x63 / 255, alpha: 1)
            : NSColor(red: 0x00 / 255, green: 0x80 / 255, blue: 0x69 / 255, alpha: 1)
    }

    static let avatarColors: [Color] = [
        Color(red: 0.91, green: 0.45, blue: 0.36),
        Color(red: 0.35, green: 0.55, blue: 0.9),
        Color(red: 0.62, green: 0.42, blue: 0.85),
        Color(red: 0.95, green: 0.66, blue: 0.25),
        Color(red: 0.88, green: 0.38, blue: 0.6),
        Color(red: 0.25, green: 0.7, blue: 0.62)
    ]

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func avatar(_ index: Int) -> Color {
        avatarColors[abs(index) % avatarColors.count]
    }
}

enum Formatters {
    static func phone(_ text: String) -> String {
        guard text.hasPrefix("+") else { return text }
        let digits = String(text.dropFirst())
        guard digits.allSatisfy(\.isNumber) else { return text }
        guard digits.hasPrefix("55"), digits.count == 12 || digits.count == 13 else { return text }
        let area = digits.dropFirst(2).prefix(2)
        let number = digits.dropFirst(4)
        return "+55 \(area) \(number.dropLast(4))-\(number.suffix(4))"
    }

    static func listTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Ontem" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide)).capitalized
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func daySeparator(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Hoje" }
        if calendar.isDateInYesterday(date) { return "Ontem" }
        return date.formatted(date: .long, time: .omitted)
    }
}

struct WideLockIcon: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { context, canvas in
            let w = canvas.width
            let h = canvas.height
            let inset = lineWidth / 2
            let body = CGRect(x: inset, y: h * 0.44, width: w - lineWidth, height: h * 0.56 - inset)
            context.stroke(Path(roundedRect: body, cornerRadius: w * 0.16), with: .foreground, lineWidth: lineWidth)
            var shackle = Path()
            let shackleWidth = w * 0.52
            let left = (w - shackleWidth) / 2
            let radius = shackleWidth / 2
            shackle.move(to: CGPoint(x: left, y: body.minY))
            shackle.addLine(to: CGPoint(x: left, y: radius + inset))
            shackle.addArc(center: CGPoint(x: w / 2, y: radius + inset), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            shackle.addLine(to: CGPoint(x: left + shackleWidth, y: body.minY))
            context.stroke(shackle, with: .foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            let dot = CGRect(x: w / 2 - w * 0.06, y: body.midY - w * 0.06, width: w * 0.12, height: w * 0.12)
            context.fill(Path(ellipseIn: dot), with: .foreground)
        }
        .frame(width: size * 1.05, height: size)
    }
}

struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.backgroundColor = Palette.backgroundNS }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.backgroundColor = Palette.backgroundNS
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func hiddenSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
