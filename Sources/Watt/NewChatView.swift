import SwiftUI

struct NewChatView: View {
    @Environment(ChatStore.self) private var store
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.contacts }
        let digits = q.filter(\.isNumber)
        return store.contacts.filter { contact in
            contact.name.lowercased().contains(q)
                || (!digits.isEmpty && contact.id.split(separator: "@").first?.contains(digits) == true)
        }
    }

    private var sections: [(letter: String, contacts: [Contact])] {
        let grouped = Dictionary(grouping: filtered) { contact -> String in
            let first = contact.name
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .first { $0.isLetter }
            return first.map { String($0).uppercased() } ?? "#"
        }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        .map { ($0, grouped[$0] ?? []) }
    }

    private var typedNumber: String? {
        let digits = query.filter(\.isNumber)
        guard digits.count >= 10, query.allSatisfy({ $0.isNumber || " +-()".contains($0) }) else { return nil }
        return digits
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let number = typedNumber {
                        actionRow("Conversar com \(Formatters.phone("+" + number))", systemImage: "message.fill") {
                            store.newChat(phone: number)
                        }
                    }
                    if query.isEmpty, let selfJID = store.selfJID {
                        selfRow(selfJID)
                    }
                    ForEach(sections, id: \.letter) { section in
                        Text(section.letter)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                        ForEach(section.contacts) { contact in
                            contactRow(contact)
                        }
                    }
                    if store.contacts.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else if filtered.isEmpty && typedNumber == nil {
                        Text("Nenhum contato encontrado")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .thinScrollers()
            }
        }
        .onAppear { searchFocused = true }
        .onExitCommand { store.isComposing = false }
        .toolbar {
            ToolbarItem {
                Text("Nova conversa")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .hiddenSharedBackground()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem {
                Button("Voltar", systemImage: "chevron.left") {
                    store.isComposing = false
                }
                .help("Voltar")
            }
        }
    }

    private var searchField: some View {
        SearchField(prompt: "Pesquisar nome ou número", text: $query, focused: $searchFocused) {
            if let number = typedNumber {
                store.newChat(phone: number)
            } else if let first = filtered.first {
                store.openChat(jid: first.id, name: first.name)
            }
        }
    }

    private func selfRow(_ jid: String) -> some View {
        let number = "+" + (jid.split(separator: "@").first.map(String.init) ?? "")
        return Button {
            store.openChat(jid: jid, name: Formatters.phone(number) + " (você)")
        } label: {
            HStack(spacing: 16) {
                AvatarView(name: store.selfName, colorIndex: 0, size: 50, imagePath: store.avatarPath(for: jid))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Formatters.phone(number)) (você)")
                        .font(.system(size: 15))
                    Text("Mensagens para mim")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .rowStyle()
        }
        .buttonStyle(HoverRowStyle())
        .pointerStyle(.link)
    }

    private func contactRow(_ contact: Contact) -> some View {
        Button {
            store.openChat(jid: contact.id, name: contact.name)
        } label: {
            HStack(spacing: 16) {
                AvatarView(
                    name: contact.name,
                    colorIndex: contact.id.unicodeScalars.reduce(0) { $0 + Int($1.value) },
                    size: 50,
                    imagePath: store.avatarPath(for: contact.id)
                )
                Text(contact.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Spacer()
            }
            .rowStyle()
        }
        .buttonStyle(HoverRowStyle())
        .pointerStyle(.link)
        .onAppear { store.requestContactAvatar(contact.id) }
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Palette.accent))
                Text(title)
                    .font(.system(size: 15))
                Spacer()
            }
            .rowStyle()
        }
        .buttonStyle(HoverRowStyle())
        .pointerStyle(.link)
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule().fill(Color.primary.opacity(focused.wrappedValue ? 0.09 : 0.06)))
    }
}

private extension View {
    func rowStyle() -> some View {
        padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
    }
}

struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))
            )
            .onHover { hovering = $0 }
    }
}
