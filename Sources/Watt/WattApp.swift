import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ToolbarCursor.shared.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct WattApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var accounts = AccountManager()
    @State private var confirmLogout = false

    var body: some Scene {
        WindowGroup("Watt") {
            ContentView()
                .id(accounts.currentID)
                .environment(accounts)
                .environment(accounts.current)
                .frame(minWidth: 820, minHeight: 540)
                .tint(Palette.accent)
                .onAppear { delegate.onTerminate = { [accounts] in accounts.shutdown() } }
                .confirmationDialog("Desconectar esta conta?", isPresented: $confirmLogout) {
                    Button("Desconectar", role: .destructive) { accounts.current.logout() }
                } message: {
                    Text("O Watt será removido dos aparelhos conectados desta conta e o histórico local dela será apagado.")
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .systemServices) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .appSettings) {
                Button("Configurações") { accounts.settingsAccountID = accounts.currentID }
            }
            CommandGroup(replacing: .newItem) {
                Button("Nova conversa") {
                    NotificationCenter.default.post(name: .wattNewChat, object: nil)
                }
                .keyboardShortcut("n")
            }
            CommandMenu("Conta") {
                ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { index, account in
                    let title = account.name.isEmpty ? (account.phone ?? "Nova conta") : account.name
                    if index < 9 {
                        Toggle(title, isOn: Binding(get: { accounts.currentID == account.id }, set: { _ in accounts.switchTo(account.id) }))
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    } else {
                        Toggle(title, isOn: Binding(get: { accounts.currentID == account.id }, set: { _ in accounts.switchTo(account.id) }))
                    }
                }
                Divider()
                Button("Adicionar conta") { accounts.addAccount() }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                Divider()
                Button("Reconectar") { accounts.current.startBridge() }
                Button("Desconectar…") { confirmLogout = true }
                    .disabled(!accounts.current.isConnected)
            }
        }
    }
}

extension Notification.Name {
    static let wattNewChat = Notification.Name("wattNewChat")
}
