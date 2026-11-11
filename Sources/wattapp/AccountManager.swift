import Foundation
import Observation

struct AccountInfo: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var jid: String?
    var theme: String?
    var plainAccent: Bool?

    var phone: String? {
        jid.flatMap { $0.split(separator: "@").first }.map { Formatters.phone("+" + $0) }
    }
}

@MainActor
@Observable
final class AccountManager {
    var accounts: [AccountInfo] = []
    var currentID: String = ""
    var settingsAccountID: String?
    @ObservationIgnored private(set) var stores: [String: ChatStore] = [:]
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var accountsDir: URL { root.appendingPathComponent("accounts", isDirectory: true) }
    @ObservationIgnored private var indexURL: URL { root.appendingPathComponent("accounts.json") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("WattApp", isDirectory: true)
        Self.migrateRename(from: support.appendingPathComponent("Watt", isDirectory: true), to: root)
        try? FileManager.default.createDirectory(at: accountsDir, withIntermediateDirectories: true)
        accounts = loadIndex()
        if accounts.isEmpty {
            let id = migrateLegacy() ? "main" : Self.newID()
            accounts = [AccountInfo(id: id, name: "", jid: nil)]
            saveIndex()
        }
        for account in accounts { startStore(for: account) }
        let saved = UserDefaults.standard.string(forKey: "currentAccount")
        currentID = accounts.contains { $0.id == saved } ? saved! : accounts[0].id
    }

    var current: ChatStore { stores[currentID]! }

    func store(for id: String) -> ChatStore? { stores[id] }

    func switchTo(_ id: String) {
        guard stores[id] != nil, id != currentID else { return }
        currentID = id
        UserDefaults.standard.set(id, forKey: "currentAccount")
    }

    func switchTo(index: Int) {
        guard accounts.indices.contains(index) else { return }
        switchTo(accounts[index].id)
    }

    func addAccount() {
        if let pending = accounts.first(where: { $0.jid == nil }) {
            switchTo(pending.id)
            return
        }
        let account = AccountInfo(id: Self.newID(), name: "", jid: nil)
        accounts.append(account)
        saveIndex()
        startStore(for: account)
        switchTo(account.id)
    }

    func cancelPending(_ id: String) {
        guard accounts.count > 1, let account = accounts.first(where: { $0.id == id }), account.jid == nil else { return }
        remove(id)
    }

    func avatarPath(for account: AccountInfo) -> String? {
        guard let jid = account.jid else { return nil }
        return stores[account.id]?.avatarPath(for: jid)
    }

    var currentTheme: String? {
        accounts.first { $0.id == currentID }?.theme
    }

    var currentAccentFollowsTheme: Bool {
        accounts.first { $0.id == currentID }?.plainAccent != true
    }

    func setAccentFollowsTheme(_ id: String, _ follows: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].plainAccent = follows ? nil : true
        saveIndex()
    }

    func setTheme(_ id: String, hex: String?) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].theme != hex else { return }
        accounts[i].theme = hex
        saveIndex()
    }

    func unread(for account: AccountInfo) -> Int {
        guard let store = stores[account.id], store.isSynced else { return 0 }
        return store.unreadTotal
    }

    func hasUnread(for account: AccountInfo) -> Bool {
        guard let store = stores[account.id], store.isSynced else { return false }
        return store.unreadTotal > 0 || store.archivedUnreadCount > 0 || store.lockedUnreadCount > 0
    }

    func shutdown() {
        for store in stores.values { store.shutdown() }
    }

    private func remove(_ id: String) {
        stores[id]?.shutdown()
        stores[id] = nil
        accounts.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: accountsDir.appendingPathComponent(id))
        UserDefaults.standard.removeObject(forKey: "deletedChats.\(id)")
        if accounts.isEmpty {
            let account = AccountInfo(id: Self.newID(), name: "", jid: nil)
            accounts = [account]
            startStore(for: account)
        }
        saveIndex()
        if currentID == id || stores[currentID] == nil {
            currentID = accounts[0].id
            UserDefaults.standard.set(currentID, forKey: "currentAccount")
        }
    }

    private func startStore(for account: AccountInfo) {
        let store = ChatStore(accountID: account.id, directory: accountsDir.appendingPathComponent(account.id, isDirectory: true))
        let id = account.id
        store.onIdentity = { [weak self] jid, name in
            self?.updateIdentity(id, jid: jid, name: name)
        }
        store.onLoggedOut = { [weak self] in
            guard let self, self.accounts.count > 1 else { return false }
            Task { @MainActor in self.remove(id) }
            return true
        }
        stores[account.id] = store
    }

    private func updateIdentity(_ id: String, jid: String, name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let duplicate = accounts.first(where: { $0.id != id && $0.jid == jid }) {
            let keep = duplicate.id
            Task { @MainActor in
                self.remove(id)
                self.switchTo(keep)
            }
            return
        }
        guard accounts[i].jid != jid || accounts[i].name != name else { return }
        accounts[i].jid = jid
        if !name.isEmpty { accounts[i].name = name }
        saveIndex()
    }

    private func loadIndex() -> [AccountInfo] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([AccountInfo].self, from: data)) ?? []
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func migrateRename(from oldRoot: URL, to newRoot: URL) {
        let fm = FileManager.default
        if let bundleID = Bundle.main.bundleIdentifier,
           UserDefaults.standard.persistentDomain(forName: bundleID)?.isEmpty ?? true,
           let legacy = UserDefaults.standard.persistentDomain(forName: "com.glhrmoura.watt"), !legacy.isEmpty {
            UserDefaults.standard.setPersistentDomain(legacy, forName: bundleID)
        }
        guard fm.fileExists(atPath: oldRoot.path), !fm.fileExists(atPath: newRoot.path) else { return }
        guard (try? fm.moveItem(at: oldRoot, to: newRoot)) != nil else { return }
        let oldPrefix = oldRoot.path + "/"
        let newPrefix = newRoot.path + "/"
        let escapedOld = oldPrefix.replacingOccurrences(of: "/", with: "\\/")
        let escapedNew = newPrefix.replacingOccurrences(of: "/", with: "\\/")
        let accounts = newRoot.appendingPathComponent("accounts", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? []
        for cache in dirs.map({ $0.appendingPathComponent("wa-chats.json") }) + [newRoot.appendingPathComponent("wa-chats.json")] {
            guard let text = try? String(contentsOf: cache, encoding: .utf8) else { continue }
            let updated = text
                .replacingOccurrences(of: escapedOld, with: escapedNew)
                .replacingOccurrences(of: oldPrefix, with: newPrefix)
            if updated != text { try? updated.write(to: cache, atomically: true, encoding: .utf8) }
        }
    }

    private func migrateLegacy() -> Bool {
        let fm = FileManager.default
        let names = ["whatsapp.db", "whatsapp.db-wal", "whatsapp.db-shm", "wa-chats.json", "avatars", "media", "lock-sync-v1"]
        guard names.contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }) else { return false }
        let target = accountsDir.appendingPathComponent("main", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names {
            let source = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.moveItem(at: source, to: target.appendingPathComponent(name))
        }
        let cache = target.appendingPathComponent("wa-chats.json")
        if let text = try? String(contentsOf: cache, encoding: .utf8) {
            let oldPrefix = root.path + "/"
            let escapedOld = oldPrefix.replacingOccurrences(of: "/", with: "\\/")
            let newPrefix = target.path + "/"
            let escapedNew = newPrefix.replacingOccurrences(of: "/", with: "\\/")
            let updated = text
                .replacingOccurrences(of: escapedOld + "avatars", with: escapedNew + "avatars")
                .replacingOccurrences(of: escapedOld + "media", with: escapedNew + "media")
                .replacingOccurrences(of: oldPrefix + "avatars", with: newPrefix + "avatars")
                .replacingOccurrences(of: oldPrefix + "media", with: newPrefix + "media")
            try? updated.write(to: cache, atomically: true, encoding: .utf8)
        }
        if let deleted = UserDefaults.standard.stringArray(forKey: "deletedChats") {
            UserDefaults.standard.set(deleted, forKey: "deletedChats.main")
            UserDefaults.standard.removeObject(forKey: "deletedChats")
        }
        return true
    }

    private static func newID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
