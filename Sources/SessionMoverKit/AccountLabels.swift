import Foundation

/// User-given names for account and organization ids. Account ids are server ids, the same in every copy,
/// so one label covers an account everywhere.
public struct AccountLabels: Codable, Equatable, Sendable {
    public var accounts: [String: String] = [:]
    public var orgs: [String: String] = [:]
    public init() {}
    enum CodingKeys: String, CodingKey { case accounts, orgs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try? c.decodeIfPresent([String: String].self, forKey: .accounts)) ?? [:]
        orgs = (try? c.decodeIfPresent([String: String].self, forKey: .orgs)) ?? [:]
    }

    public func name(forAccount id: String) -> String? { accounts[id].flatMap { $0.isEmpty ? nil : $0 } }
    public func name(forOrg id: String) -> String? { orgs[id].flatMap { $0.isEmpty ? nil : $0 } }

    /// The label, or the id tail (`3c91e0a7`).
    public func display(account id: String) -> String { name(forAccount: id) ?? Self.shortID(id) }
    public func display(org id: String) -> String { name(forOrg: id) ?? Self.shortID(id) }
    public static func shortID(_ id: String) -> String { String(id.prefix(8)) }

    /// "Team account", "you@example.com", or "account 3c91e0a7" when unnamed.
    public func phrase(account id: String) -> String {
        guard let n = name(forAccount: id) else { return "account \(Self.shortID(id))" }
        return n.contains("@") ? n : "\(n) account"
    }

    public mutating func setAccount(_ id: String, name: String?) {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        accounts[id] = t.isEmpty ? nil : t
    }
    public mutating func setOrg(_ id: String, name: String?) {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        orgs[id] = t.isEmpty ? nil : t
    }
}

/// "A copy of this session was opened in another copy of Claude". Keyed by the source's local id and the destination.
public struct CopiedMark: Codable, Hashable, Sendable {
    public var sourceID: String
    public var sourceBundleID: String
    public var destBundleID: String
    public var destName: String
    public var createdAt: Date
    /// The journal entry of the copy in History.
    public var moveID: String
    public init(sourceID: String, sourceBundleID: String, destBundleID: String, destName: String, createdAt: Date, moveID: String) {
        self.sourceID = sourceID; self.sourceBundleID = sourceBundleID; self.destBundleID = destBundleID
        self.destName = destName; self.createdAt = createdAt; self.moveID = moveID
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var labels = AccountLabels()
    public var firstRunCompleted = false
    public var hiddenCalloutDismissed = false
    /// Slugs the move engine may write to (see `WritePolicy`). nil: use the default.
    public var writableInstances: [String]?
    /// The menu bar extra. nil: on.
    public var showMenuBarExtra: Bool?
    public var menuBarExtraEnabled: Bool { showMenuBarExtra ?? true }
    /// Source rows that show the "Copied" chip.
    public var copied: [CopiedMark] = []
    public init() {}

    /// One mark per source and destination: a second copy replaces the first.
    public mutating func addCopyMark(_ m: CopiedMark) {
        copied.removeAll { $0.sourceID == m.sourceID && $0.sourceBundleID == m.sourceBundleID && $0.destBundleID == m.destBundleID }
        copied.append(m)
    }
    public mutating func removeCopyMarks(moveID: String) { copied.removeAll { $0.moveID == moveID } }

    enum CodingKeys: String, CodingKey { case labels, firstRunCompleted, hiddenCalloutDismissed, writableInstances, showMenuBarExtra, copied }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = (try? c.decodeIfPresent(AccountLabels.self, forKey: .labels)) ?? AccountLabels()
        firstRunCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .firstRunCompleted)) ?? false
        hiddenCalloutDismissed = (try? c.decodeIfPresent(Bool.self, forKey: .hiddenCalloutDismissed)) ?? false
        writableInstances = try? c.decodeIfPresent([String].self, forKey: .writableInstances)
        showMenuBarExtra = try? c.decodeIfPresent(Bool.self, forKey: .showMenuBarExtra)
        copied = (try? c.decodeIfPresent([CopiedMark].self, forKey: .copied)) ?? []
    }
}

/// `~/Library/Application Support/SessionMover/settings.json`: the only file Phase 1 writes.
public struct SettingsStore: Sendable {
    public let file: URL
    public init(env: SMEnvironment) { file = env.settingsFile }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: file),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(_ settings: AppSettings) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(settings)
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(file, withItemAt: tmp)
    }
}
