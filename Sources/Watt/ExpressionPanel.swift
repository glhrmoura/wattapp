import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

enum ExpressionTab: Hashable { case emoji, sticker }

struct ExpressionPanel: View {
    @Environment(\.colorScheme) private var scheme
    var onEmoji: (String) -> Void
    var onSticker: (URL) -> Void
    @State private var tab: ExpressionTab = .emoji
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Insira texto ou emojis", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().stroke(searchFocused ? Palette.accent : Color.primary.opacity(0.1), lineWidth: searchFocused ? 2 : 1))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack(spacing: 2) {
                tabButton(.emoji) { Image(systemName: "face.smiling").font(.system(size: 17)) }
                tabButton(.sticker) {
                    StickerIcon()
                        .stroke(style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .frame(width: 17, height: 17)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
            .padding(.vertical, 12)

            Group {
                switch tab {
                case .emoji: EmojiGrid(query: query, onPick: onEmoji)
                case .sticker: StickerGrid(onPick: onSticker)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 380, height: 560)
        .onChange(of: tab) { query = "" }
    }

    private func tabButton<Label: View>(_ value: ExpressionTab, @ViewBuilder label: () -> Label) -> some View {
        Button { tab = value } label: {
            label()
                .foregroundStyle(tab == value ? .primary : .secondary)
                .frame(width: 52, height: 30)
                .background(Capsule().fill(tab == value ? Color.primary.opacity(scheme == .dark ? 0.16 : 0.1) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

struct CategoryBar: View {
    let items: [(id: Int, symbol: String, title: String)]
    let selected: Int
    var onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(items, id: \.id) { item in
                    Button { onSelect(item.id) } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(selected == item.id ? .primary : .secondary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(selected == item.id ? Color.primary.opacity(0.12) : .clear))
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help(item.title)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

struct EmojiGrid: View {
    let query: String
    var onPick: (String) -> Void
    private let columnCount: Int
    private let uppercase: Bool
    private let recentTitle: String
    @AppStorage private var recentRaw: String
    @State private var selected = 0

    init(query: String, columns: Int = 9, uppercase: Bool = false, recentTitle: String = "Recentes", storageKey: String = "recentEmojis", onPick: @escaping (String) -> Void) {
        self.query = query
        self.onPick = onPick
        columnCount = columns
        self.uppercase = uppercase
        self.recentTitle = recentTitle
        _recentRaw = AppStorage(wrappedValue: "", storageKey)
    }

    private static let titles = ["Smileys e pessoas", "Animais e natureza", "Comidas e bebidas", "Atividades", "Viagens e lugares", "Objetos", "Símbolos", "Bandeiras"]
    private static let symbols = ["face.smiling", "teddybear", "cup.and.saucer", "soccerball", "car", "lightbulb", "number.square", "flag"]
    private static let categories = EmojiData.categories.map { $0.split(separator: " ").map(String.init) }
    private static let names: [(String, String)] = EmojiData.names.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 0), count: columnCount) }
    private var recents: [String] { recentRaw.split(separator: " ").map(String.init) }

    private var results: [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let all = Self.categories.flatMap { $0 }
        if all.contains(needle) { return [needle] }
        return Self.names.filter { $0.1.contains(needle) }.map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                        if !query.isEmpty {
                            section("Resultados", results)
                            if results.isEmpty {
                                Text("Nenhum emoji encontrado")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                        } else {
                            if !recents.isEmpty {
                                section(recentTitle, recents).id(-1)
                            }
                            ForEach(Self.categories.indices, id: \.self) { index in
                                section(Self.titles[index], Self.categories[index]).id(index)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                if query.isEmpty {
                    CategoryBar(
                        items: [(-1, "clock", recentTitle)] + Self.symbols.indices.map { ($0, Self.symbols[$0], Self.titles[$0]) },
                        selected: selected
                    ) { id in
                        selected = id
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(uppercase ? title.uppercased() : title)
                .font(.system(size: uppercase ? 13 : 14, weight: uppercase ? .medium : .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 8)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in
                    EmojiCell(emoji: emoji) { pick(emoji) }
                }
            }
        }
    }

    private func pick(_ emoji: String) {
        var list = recents.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentRaw = list.prefix(18).joined(separator: " ")
        onPick(emoji)
    }
}

private struct EmojiCell: View {
    let emoji: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 26))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct StickerGrid: View {
    @Environment(ChatStore.self) private var store
    var onPick: (URL) -> Void
    @AppStorage(StickerFavorites.key) private var favoritesRaw = ""
    @State private var recents: [String] = []
    @State private var section = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private var favorites: [String] {
        favoritesRaw.split(separator: "\n").map(String.init).filter { FileManager.default.fileExists(atPath: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        header("Recentes").id(0)
                        LazyVGrid(columns: columns, spacing: 8) {
                            createTile
                            ForEach(recents, id: \.self) { cell($0) }
                        }
                        if !favorites.isEmpty {
                            header("Favoritas").id(1)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(favorites, id: \.self) { cell($0) }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                CategoryBar(items: [(0, "clock", "Recentes"), (1, "star", "Favoritas")], selected: section) { id in
                    section = id
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .task { recents = await Self.collect(store.chats.flatMap(\.messages)) }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }

    private var createTile: some View {
        Button(action: create) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.08))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 5) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 16))
                        Text("Criar\nfigurinha")
                            .font(.system(size: 11.5, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    private func cell(_ path: String) -> some View {
        let isFavorite = favorites.contains(path)
        return Group {
            if let animation = ImageAnimation.load(path: path) {
                AnimatedImage(animation: animation)
            } else if let image = ImageCache.shared.image(at: path) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { onPick(URL(fileURLWithPath: path)) }
        .pointerStyle(.link)
        .contextMenu {
            Button(isFavorite ? "Remover das favoritas" : "Adicionar às favoritas", systemImage: isFavorite ? "star.slash" : "star") {
                var list = favorites.filter { $0 != path }
                if !isFavorite { list.insert(path, at: 0) }
                favoritesRaw = list.joined(separator: "\n")
            }
        }
    }

    private func create() {
        AttachmentPicker.choose(types: [.image]) { urls in
            guard let url = urls.first,
                  let output = Self.renderSticker(from: url) else { return }
            onPick(output)
        }
    }

    static func renderSticker(from url: URL) -> URL? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let side: CGFloat = 512
        let size = image.size
        let scale = min(side / max(size.width, 1), side / max(size.height, 1))
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Watt")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("sticker-\(UUID().uuidString).png")
        return (try? data.write(to: output)) != nil ? output : nil
    }

    nonisolated static func collect(_ messages: [Message]) async -> [String] {
        let candidates = messages
            .filter { $0.mediaKind == "sticker" && $0.mediaPath != nil }
            .sorted { $0.date > $1.date }
            .compactMap(\.mediaPath)
        return await Task.detached {
            var seen = Set<String>()
            var result: [String] = []
            for path in candidates where result.count < 60 {
                guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { continue }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if seen.insert(digest).inserted { result.append(path) }
            }
            return result
        }.value
    }
}

struct StickerIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width * 0.28
        let fold = rect.width * 0.42
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - fold, y: rect.maxY), control: CGPoint(x: rect.maxX - fold, y: rect.maxY - fold))
        return path
    }
}

enum StickerFavorites {
    static let key = "favoriteStickers"

    static var paths: [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "\n").map(String.init)
    }

    static func contains(_ path: String) -> Bool { paths.contains(path) }

    static func toggle(_ path: String) {
        var list = paths.filter { $0 != path }
        if !contains(path) { list.insert(path, at: 0) }
        UserDefaults.standard.set(list.joined(separator: "\n"), forKey: key)
    }
}
