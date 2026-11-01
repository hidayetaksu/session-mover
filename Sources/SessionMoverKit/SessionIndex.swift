import Foundation

/// Tolerant summary of one `local_<id>.json` sidebar entry. Unknown fields are ignored.
public struct SessionSummary: Sendable, Hashable {
    public var title: String?
    public var cliSessionId: String?
    public var sessionId: String?
    public var cwd: String?
    public var originCwd: String?
    public var createdAt: Date?
    public var lastActivityAt: Date?
    public var isArchived = false
    public var isStarred = false
    public var model: String?
    public var permissionMode: String?
    public var branch: String?
    public var worktreeName: String?
    public var worktreePath: String?
    public var spawnedFromID: String?
    public var forkedFromID: String?
    public var prNumbers: [Int] = []
    public var errorText: String?
    public var errorAt: Date?
    /// Filled in at scan time: does `cwd` still exist on disk? nil when the entry has no folder.
    public var folderExists: Bool?

    public var isLimitError: Bool {
        guard let e = errorText else { return false }
        return e.range(of: "limit", options: .caseInsensitive) != nil
    }

    /// "1:30am" from "You've hit your session limit · resets 1:30am (America/Los_Angeles)".
    public var limitResets: String? {
        guard let e = errorText, isLimitError,
              let r = e.range(of: #"resets\s+([^()·]+)"#, options: .regularExpression) else { return nil }
        return String(e[r]).replacingOccurrences(of: "resets", with: "").trimmingCharacters(in: .whitespaces)
    }

    public var projectPath: String? { nonEmpty(originCwd) ?? nonEmpty(cwd) }
    private func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
}

public struct SessionEntry: Identifiable, Sendable, Hashable {
    /// `local_<id>`, or the file name when the file could not be read.
    public let id: String
    public let instanceID: String
    public let accountID: String
    public let orgID: String
    public let fileURL: URL
    public var summary: SessionSummary?
    public var readError: String?

    public var isUnreadable: Bool { summary == nil }
    public var displayTitle: String {
        if isUnreadable { return fileURL.lastPathComponent }
        if let t = summary?.title, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        return "Untitled session"
    }
    public var folderName: String? { summary?.projectPath.map { ($0 as NSString).lastPathComponent } }
    /// Branch, or the worktree name when no branch is recorded.
    public var branchOrWorktree: String? { summary?.branch ?? summary?.worktreeName }
}

public struct OrgFolder: Sendable, Hashable {
    public let accountID: String
    public let orgID: String
    public let url: URL
    public var entries: [SessionEntry]
    /// Ids listed in `archived-sessions.idx` (a load-order hint; `isArchived` in the entry is the truth).
    public var archivedHint: Set<String>?
}

public struct InstanceScan: Sendable, Identifiable {
    public var instance: Instance
    public var signedInAccountID: String?
    public var orgs: [OrgFolder]
    public var scanError: String?
    public var id: String { instance.id }

    public var entries: [SessionEntry] { orgs.flatMap(\.entries) }
    public var accountIDs: [String] {
        var seen: [String] = []
        for o in orgs where !seen.contains(o.accountID) { seen.append(o.accountID) }
        // Signed-in account first, then folder-name order.
        return seen.sorted { a, b in
            if (a == signedInAccountID) != (b == signedInAccountID) { return a == signedInAccountID }
            return a < b
        }
    }
    public func orgIDs(in account: String) -> [String] {
        orgs.filter { $0.accountID == account }.map(\.orgID).sorted()
    }
    public var unreadableCount: Int { entries.filter(\.isUnreadable).count }
}

enum SummaryParser {
    static func parse(_ data: Data) -> Result<SessionSummary, ReadFailure> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return .failure(.init("not valid JSON")) }
        guard let d = obj as? [String: Any] else { return .failure(.init("not a JSON object")) }
        var s = SessionSummary()
        s.title = d["title"] as? String
        s.cliSessionId = d["cliSessionId"] as? String
        s.sessionId = d["sessionId"] as? String
        s.cwd = d["cwd"] as? String
        s.originCwd = d["originCwd"] as? String
        s.createdAt = date(d["createdAt"])
        s.lastActivityAt = date(d["lastActivityAt"])
        s.isArchived = bool(d["isArchived"])
        s.isStarred = bool(d["isStarred"])
        s.model = d["model"] as? String
        s.permissionMode = d["permissionMode"] as? String
        s.branch = d["branch"] as? String
        s.worktreeName = d["worktreeName"] as? String
        s.worktreePath = d["worktreePath"] as? String
        if let sp = d["spawnedFrom"] as? [String: Any] { s.spawnedFromID = sp["sessionId"] as? String }
        else if let sp = d["spawnedFrom"] as? String { s.spawnedFromID = sp }
        s.forkedFromID = d["forkedFromSessionId"] as? String
        if let prs = d["prs"] as? [[String: Any]] { s.prNumbers = prs.compactMap { ($0["prNumber"] as? NSNumber)?.intValue } }
        s.errorText = (d["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        s.errorAt = date(d["errorAt"])
        return .success(s)
    }

    private static func bool(_ v: Any?) -> Bool {
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return false
    }

    /// Milliseconds since 1970 (Claude's format), plain seconds, numeric strings, or ISO 8601.
    static func date(_ v: Any?) -> Date? {
        func fromNumber(_ x: Double) -> Date { Date(timeIntervalSince1970: x > 1e11 ? x / 1000 : x) }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return fromNumber(n.doubleValue) }
        if let s = v as? String {
            if let x = Double(s) { return fromNumber(x) }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        return nil
    }
}

struct ReadFailure: Error, Sendable { var message: String; init(_ m: String) { message = m } }

/// Reads the `claude-code-sessions/<account>/<org>/local_*.json` tree of one instance. Read-only.
/// Parsed entries are cached by modification time and size, so a rescan after a small change is cheap.
final class SessionTreeReader: @unchecked Sendable {
    private struct Key: Hashable { var path: String; var mtime: Date; var size: Int }
    private let lock = NSLock()
    private var cache: [Key: Result<SessionSummary, ReadFailure>] = [:]

    static func isEntryName(_ name: String) -> Bool { name.hasPrefix("local_") && name.hasSuffix(".json") }

    func read(instance: Instance) -> (orgs: [OrgFolder], error: String?) {
        let fm = FileManager.default
        let root = instance.sessionsRoot
        guard fm.fileExists(atPath: instance.dataURL.path) else {
            return ([], "The folder \(Self.tilde(instance.dataURL.path)) is missing.")
        }
        guard fm.fileExists(atPath: root.path) else { return ([], nil) } // never had a Code session
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else {
            return ([], "Couldn't read \(Self.tilde(root.path)).")
        }
        var orgs: [OrgFolder] = []
        var liveKeys = Set<Key>()
        for acct in accounts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where isDir(acct) {
            let orgDirs = (try? fm.contentsOfDirectory(at: acct, includingPropertiesForKeys: keys)) ?? []
            for org in orgDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where isDir(org) {
                var entries: [SessionEntry] = []
                let files = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: keys)) ?? []
                for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where Self.isEntryName(f.lastPathComponent) {
                    let vals = try? f.resourceValues(forKeys: Set(keys))
                    let id = String(f.lastPathComponent.dropLast(".json".count))
                    let key = Key(path: f.path, mtime: vals?.contentModificationDate ?? .distantPast, size: vals?.fileSize ?? -1)
                    liveKeys.insert(key)
                    var entry = SessionEntry(id: id, instanceID: instance.id, accountID: acct.lastPathComponent,
                                             orgID: org.lastPathComponent, fileURL: f)
                    switch parsed(f, key) {
                    case .success(var s):
                        if let cwd = s.cwd, !cwd.isEmpty { s.folderExists = fm.fileExists(atPath: cwd) }
                        entry.summary = s
                    case .failure(let e):
                        entry.readError = e.message
                    }
                    entries.append(entry)
                }
                orgs.append(OrgFolder(accountID: acct.lastPathComponent, orgID: org.lastPathComponent, url: org,
                                      entries: entries, archivedHint: archivedHint(org)))
            }
        }
        lock.lock(); cache = cache.filter { liveKeys.contains($0.key) }; lock.unlock()
        return (orgs, nil)
    }

    private func parsed(_ url: URL, _ key: Key) -> Result<SessionSummary, ReadFailure> {
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        let result: Result<SessionSummary, ReadFailure>
        if let data = try? Data(contentsOf: url) { result = SummaryParser.parse(data) }
        else { result = .failure(.init("couldn't be read")) }
        lock.lock(); cache[key] = result; lock.unlock()
        return result
    }

    private func archivedHint(_ org: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: org.appendingPathComponent("archived-sessions.idx")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = obj["archived"] as? [String] else { return nil }
        return Set(ids)
    }

    private func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }

    static func tilde(_ path: String) -> String {
        let h = NSHomeDirectory()
        return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
    }
}
