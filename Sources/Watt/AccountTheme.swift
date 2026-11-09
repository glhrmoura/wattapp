import SwiftUI
import AppKit

struct ThemePreset: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
}

enum AccountTheme {
    static let presets: [ThemePreset] = [
        ThemePreset(name: "Aubergine", hex: "431349:200221"),
        ThemePreset(name: "Clementine", hex: "7A2500:381000"),
        ThemePreset(name: "Banana", hex: "674800:2F1E00"),
        ThemePreset(name: "Jade", hex: "083F2E:05241B"),
        ThemePreset(name: "Lagoon", hex: "003D61:001A2D"),
        ThemePreset(name: "Barbra", hex: "6B0518:300005"),
        ThemePreset(name: "Gray", hex: "212428:101214"),
        ThemePreset(name: "Mood Indigo", hex: "12206C:040B3D")
    ]

    static let milesPresets: [ThemePreset] = [
        ThemePreset(name: "Kind of Blue", hex: "4B799A:0A3753"),
        ThemePreset(name: "Funky Fresh", hex: "7D72A6:2D8A59"),
        ThemePreset(name: "Jazz Club", hex: "8C1010:040838"),
        ThemePreset(name: "Electric Fusion", hex: "8C9D58:5FA676"),
        ThemePreset(name: "Brassy", hex: "9D8638:786526"),
        ThemePreset(name: "Sunglasses Inside", hex: "330E37:140114")
    ]

    static var allPresets: [ThemePreset] { presets + milesPresets }

    static func color(_ hex: String) -> NSColor? {
        let digits = String(hex.split(separator: ":").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    static func colors(_ hex: String) -> (primary: Color, highlight: Color)? {
        guard let primary = color(hex) else { return nil }
        let parts = hex.split(separator: ":")
        let highlight = parts.count > 1 ? color(String(parts[1])) : nil
        return (Color(nsColor: primary), Color(nsColor: highlight ?? primary.blended(withFraction: 0.55, of: .black) ?? primary))
    }
}

struct ThemeBackdrop: View {
    let hex: String

    var body: some View {
        if let colors = AccountTheme.colors(hex) {
            GeometryReader { proxy in
                let radius = hypot(proxy.size.width, proxy.size.height) / 2
                ZStack {
                    AngularGradient(
                        colors: [colors.highlight, colors.primary, colors.highlight, colors.primary, colors.highlight],
                        center: .center,
                        startAngle: .degrees(-45),
                        endAngle: .degrees(315)
                    )
                    RadialGradient(
                        stops: [
                            .init(color: colors.primary, location: 0.2),
                            .init(color: colors.primary.opacity(0), location: 0.8)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    )
                }
            }
        }
    }
}

struct ChromeBackground: View {
    let theme: String?

    var body: some View {
        if let theme, AccountTheme.color(theme) != nil {
            ThemeBackdrop(hex: theme)
        } else {
            Palette.background
        }
    }
}

extension EnvironmentValues {
    @Entry var windowSize: CGSize = .zero
}

struct ThemedPanelBackground: View {
    let theme: String?

    var body: some View {
        if let theme {
            WindowAlignedBackdrop(hex: theme)
                .overlay(Color.black.opacity(0.5))
        } else {
            Palette.background
        }
    }
}

struct WindowAlignedBackdrop: View {
    @Environment(\.windowSize) private var windowSize
    let hex: String

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            ThemeBackdrop(hex: hex)
                .frame(width: max(windowSize.width, frame.maxX), height: max(windowSize.height, frame.maxY))
                .offset(x: -frame.minX, y: -frame.minY)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

struct ThemeSwatch: View {
    let hex: String?
    var custom = false
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            if custom && hex == nil {
                Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
            } else if let hex, AccountTheme.color(hex) != nil {
                ThemeBackdrop(hex: hex).clipShape(Circle())
            } else {
                Circle().fill(Palette.background)
                Image(systemName: "circle.slash")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }
}

struct ThemeCard: View {
    let name: String
    let hex: String?
    var custom = false
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ThemeSwatch(hex: hex, custom: custom)
                Text(name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.08 : hovering ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Palette.accent : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct InlineColorPicker: View {
    let hex: String
    let onChange: (String) -> Void
    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 0
    @State private var brightness: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Color(hue: hue, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .background(Circle().fill(Color(hue: hue, saturation: saturation, brightness: brightness)))
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: saturation * size.width - 8, y: (1 - brightness) * size.height - 8)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    saturation = min(max(value.location.x / size.width, 0), 1)
                    brightness = 1 - min(max(value.location.y / size.height, 0), 1)
                    commit()
                })
            }
            .frame(height: 120)
            GeometryReader { proxy in
                let width = proxy.size.width
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) }, startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .leading) {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 2)
                            .background(Circle().fill(Color(hue: hue, saturation: 1, brightness: 1)))
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: hue * width - 8)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        hue = min(max(value.location.x / width, 0), 0.999)
                        commit()
                    })
            }
            .frame(height: 12)
        }
        .onAppear { load(hex) }
        .onChange(of: hex) { _, value in
            if value != currentHex { load(value) }
        }
    }

    private var currentHex: String? {
        AccountTheme.hex(NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
    }

    private func load(_ value: String) {
        guard let color = AccountTheme.color(value)?.usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        if s > 0.001 { hue = h }
        saturation = s
        brightness = b
    }

    private func commit() {
        guard let value = currentHex else { return }
        onChange(value)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case visual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visual: "Visual"
        }
    }

    var icon: String {
        switch self {
        case .visual: "paintpalette"
        }
    }
}

struct SettingsSheet: View {
    let account: AccountInfo
    @State private var section: SettingsSection = .visual

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Configurações")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                ForEach(SettingsSection.allCases) { item in
                    SettingsSidebarRow(section: item, selected: section == item) { section = item }
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
            Divider()
            switch section {
            case .visual:
                VisualSettings(account: account)
            }
        }
        .frame(height: 560)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}

struct VisualSettings: View {
    @Environment(AccountManager.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    let account: AccountInfo
    @State private var showCustom = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var customStart: NSColor {
        current.flatMap(AccountTheme.color) ?? NSColor(srgbRed: 0x1D / 255, green: 0x3F / 255, blue: 0x5E / 255, alpha: 1)
    }

    private var current: String? {
        accounts.accounts.first { $0.id == account.id }?.theme
    }

    private var isCustom: Bool {
        guard let current else { return false }
        return !AccountTheme.allPresets.contains { $0.hex == current }
    }

    private var title: String {
        account.name.isEmpty ? (account.phone ?? "esta conta") : account.name
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .padding(24)
                    .thinScrollers()
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Concluído")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 600)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Visual")
                    .font(.system(size: 17, weight: .semibold))
                Text("Cores das bordas e dos destaques do Watt para \(title).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            preview
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destaques na cor do tema")
                        .font(.system(size: 13, weight: .medium))
                    Text("Botões, filtros e links acompanham a cor escolhida.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { accounts.accounts.first { $0.id == account.id }?.plainAccent != true },
                    set: { accounts.setAccentFollowsTheme(account.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(current == nil)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .opacity(current == nil ? 0.5 : 1)
            section("Cor única") {
                card("Padrão", hex: nil)
                ForEach(AccountTheme.presets) { preset in
                    card(preset.name, hex: preset.hex)
                }
                ThemeCard(name: "Personalizada", hex: isCustom ? current : nil, custom: true, selected: isCustom) {
                    if !isCustom { accounts.setTheme(account.id, hex: AccountTheme.hex(customStart) ?? "1D3F5E") }
                    showCustom = true
                }
                .popover(isPresented: $showCustom, arrowEdge: .trailing) {
                    if let current {
                        InlineColorPicker(hex: current) { hex in
                            accounts.setTheme(account.id, hex: hex)
                        }
                        .padding(16)
                        .frame(width: 260)
                    }
                }
            }
            section("Miles Davis") {
                ForEach(AccountTheme.milesPresets) { preset in
                    card(preset.name, hex: preset.hex)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 10) {
                content()
            }
        }
    }

    private func card(_ name: String, hex: String?) -> some View {
        ThemeCard(name: name, hex: hex, selected: current == hex) {
            showCustom = false
            accounts.setTheme(account.id, hex: hex)
        }
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            ChromeBackground(theme: current)
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 52)
            .padding(.top, 38)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<4, id: \.self) { index in
                        HStack(spacing: 8) {
                            Circle().fill(Color.white.opacity(0.16)).frame(width: 16, height: 16)
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.13)).frame(width: index.isMultiple(of: 2) ? 96 : 72, height: 6)
                        }
                    }
                }
                .padding(14)
                .frame(width: 180, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(panelTint)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                Palette.background
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            }
            .padding(.leading, 52)
            .padding(.top, 26)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var panelTint: some View {
        if let current, AccountTheme.color(current) != nil {
            ThemeBackdrop(hex: current).overlay(Color.black.opacity(0.5))
        } else {
            Palette.background
        }
    }
}
