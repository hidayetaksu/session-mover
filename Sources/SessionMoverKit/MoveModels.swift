import Foundation

// MARK: Destination

/// Where sessions go: a copy, and optionally an account and organization inside it.
/// No account means the copy's signed-in account; no organization means the session's own, else the account's only one.
public struct MoveDestination: Hashable, Sendable {
    public var instanceID: String
    public var accountID: String?
    public var orgID: String?
    public init(instanceID: String, accountID: String? = nil, orgID: String? = nil) {
        self.instanceID = instanceID; self.accountID = accountID; self.orgID = orgID
    }
}

public enum DestinationParseError: LocalizedError, Equatable {
    case unknownInstance(String)
    case unknownAccount(String)
    case ambiguous(String)
    case unknownOrg(String)
    public var errorDescription: String? {
        switch self {
        case .unknownInstance(let s): "No Claude copy matches \"\(s)\". Use a Claude Profiles slug, or \"default\" for Claude.app."
        case .unknownAccount(let s): "No account matches \"\(s)\"."
        case .ambiguous(let s): "\"\(s)\" matches more than one."
        case .unknownOrg(let s): "No organization matches \"\(s)\"."
        }
    }
}

extension MoveDestination {
    /// `<slug>[/<account>[/<org>]]`. The slug is a Claude Profiles slug, `default` (or `claude`) for Claude.app,
    /// or a copy's name. Account and org match a full id, an id prefix, or an account label.
    public static func parse(_ text: String, in library: Library, labels: AccountLabels = AccountLabels()) throws -> MoveDestination {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let head = parts[0].lowercased()
        let hits = library.instances.filter { s in
            let i = s.instance
            return i.writeSlug.lowercased() == head || i.name.lowercased() == head || i.bundleID.lowercased() == head
                || (i.isOriginal && head == "claude")
        }
        guard let inst = hits.first else { throw DestinationParseError.unknownInstance(parts[0]) }
        var dest = MoveDestination(instanceID: inst.id)
        if parts.count > 1, !parts[1].isEmpty {
            let q = parts[1].lowercased()
            let known = Set(library.accountIDs())
            let m = known.filter { $0.lowercased().hasPrefix(q) || (labels.name(forAccount: $0)?.lowercased() == q) }
            if m.count > 1 { throw DestinationParseError.ambiguous(parts[1]) }
            guard let a = m.first else { throw DestinationParseError.unknownAccount(parts[1]) }
            dest.accountID = a
        }
        if parts.count > 2, !parts[2].isEmpty {
            let q = parts[2].lowercased()
            let orgs = Set(library.instances.flatMap(\.orgs).map(\.orgID))
            let m = orgs.filter { $0.lowercased().hasPrefix(q) || (labels.name(forOrg: $0)?.lowercased() == q) }
            if m.count > 1 { throw DestinationParseError.ambiguous(parts[2]) }
            guard let o = m.first else { throw DestinationParseError.unknownOrg(parts[2]) }
            dest.orgID = o
        }
        return dest
    }
}

// MARK: Check rows

public enum CheckKind: String, Sendable, Hashable, CaseIterable {
    case allowlist, version, apps, state, others, destination, folder, lease, org, limit, family, pinned
    /// Display order of aggregated rows.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum CheckStatus: Int, Sendable, Hashable, Comparable {
    case pass = 0, warn, block
    public static func < (a: CheckStatus, b: CheckStatus) -> Bool { a.rawValue < b.rawValue }
}

public struct CheckRow: Identifiable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue)|\(sessionKey)" }
    public var kind: CheckKind
    public var status: CheckStatus
    public var title: String
    public var detail: String?
    /// `SessionPlan.id` of the session this row belongs to.
    public var sessionKey: String
    public init(_ kind: CheckKind, _ status: CheckStatus, _ title: String, detail: String? = nil, session: String = "") {
        self.kind = kind; self.status = status; self.title = title; self.detail = detail; self.sessionKey = session
    }
}

/// One row of the Move sheet: a check across every dragged session ("2 of 3" when sessions differ).
public struct AggregatedRow: Identifiable, Hashable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: CheckKind
    public var status: CheckStatus
    public var title: String
    public var detail: String?
    public var affected: [String]       // session titles with this status
    public var total: Int
}

// MARK: Plan

public struct SessionPlan: Identifiable, Sendable {
    public var id: String { entry.fileURL.path }
    public var entry: SessionEntry
    public var source: Instance
    public var destination: Instance
    public var dstAccountID: String?
    public var dstOrgID: String?
    public var dstFolder: URL?
    public var dstURL: URL?
    public var rows: [CheckRow]
    /// An entry with this id is already at the destination. Replace isn't built yet.
    public var isDuplicate: Bool
    public var leaseNames: [String]

    public var isBlocked: Bool { rows.contains { $0.status == .block } }
    public var blocks: [CheckRow] { rows.filter { $0.status == .block } }
    public var warnings: [CheckRow] { rows.filter { $0.status == .warn } }
    public var backupFolderPreview: String { "~/Library/Application Support/SessionMover/backups/" }
}

public struct MovePlan: Sendable {
    public var destination: MoveDestination
    public var destinationInstance: Instance?
    public var items: [SessionPlan]
    /// Text for the sheet header: "Client · Team account".
    public var destinationPhrase: String
    /// Copies that are open and must quit for this move (only when the plan was made to quit them).
    public var mustQuit: [Instance] = []
    /// Built to replace an entry that is already at the destination.
    public var replace = false

    public var movable: [SessionPlan] { items.filter { !$0.isBlocked } }
    public var blocked: [SessionPlan] { items.filter(\.isBlocked) }
    public var canMove: Bool { !movable.isEmpty }
    public var hasDuplicates: Bool { items.contains(where: \.isDuplicate) }

    /// "Move", "Quit & Move", "Move 2, Skip 1", "Quit & Move 3", "Replace".
    public var buttonTitle: String {
        let verb = replace ? "Replace" : (mustQuit.isEmpty ? "Move" : "Quit & Move")
        if items.count <= 1 { return verb }
        let skipped = blocked.count
        return skipped == 0 ? "\(verb) \(movable.count)" : "\(verb) \(movable.count), Skip \(skipped)"
    }

    /// Every session is held back by a busy app, so only Open a Copy can still get them across.
    public var blockedByBusyApp: Bool {
        !items.isEmpty && items.allSatisfy { s in s.blocks.contains { $0.kind == .apps } }
    }

    /// One row per check kind, worst status first within the kind; passing rows stay one line.
    public var rows: [AggregatedRow] {
        var out: [AggregatedRow] = []
        let total = items.count
        let byKind = Dictionary(grouping: items.flatMap(\.rows), by: \.kind)
        let titles = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.entry.displayTitle) })
        for kind in CheckKind.allCases {
            guard let rows = byKind[kind], !rows.isEmpty else { continue }
            let worst = rows.map(\.status).max() ?? .pass
            let hit = rows.filter { $0.status == worst }
            let sameText = Set(hit.map(\.title)).count == 1
            var title = hit[0].title
            if total > 1 && (hit.count < total || !sameText) {
                title = sameText ? "\(title) (\(hit.count) of \(total))" : "\(hit.count) of \(total): \(kind.summaryNoun)"
            }
            out.append(AggregatedRow(kind: kind, status: worst, title: title,
                                     detail: hit.count == 1 || sameText ? hit[0].detail : nil,
                                     affected: hit.compactMap { titles[$0.sessionKey] }, total: total))
        }
        return out
    }
}

extension CheckKind {
    var summaryNoun: String {
        switch self {
        case .allowlist: "moves turned off"
        case .version: "version not verified"
        case .apps: "app open"
        case .state: "session state"
        case .others: "other open sessions"
        case .destination: "destination"
        case .folder: "working folder"
        case .lease: "worktree lease"
        case .org: "organization"
        case .limit: "limit notice"
        case .family: "linked sessions"
        case .pinned: "pinned"
        }
    }
}

// MARK: Journal

public struct InstanceRef: Codable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var slug: String
    public var appPath: String
    public var dataPath: String
    public var version: String?
    public init(_ i: Instance) {
        bundleID = i.bundleID; name = i.name; slug = i.writeSlug
        appPath = i.appURL.path; dataPath = i.dataURL.path; version = i.version
    }
}

public struct MoveRecord: Codable, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case started, done, rolledBack = "rolled_back", undone }

    public struct FileBackup: Codable, Hashable, Sendable {
        public var path: String
        public var existed: Bool
        /// File name inside the move's backup folder.
        public var backup: String?
        public var mode: Int?
        public var sha256: String?
    }
    public struct MovedDir: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        /// Copied, not moved: the source stays (side-session notes).
        public var keepSource: Bool
    }
    public struct Item: Codable, Hashable, Sendable {
        public var sessionID: String
        public var title: String
        public var cliSessionId: String?
        public var from: InstanceRef
        public var fromAccountID: String
        public var fromOrgID: String
        public var srcPath: String
        public var dstPath: String
        public var srcSHA256: String
        public var dstSHA256: String?
        public var leases: [String]
        public var movedDirs: [MovedDir]
    }

    public var id: String
    public var kind: String
    public var state: State
    public var createdAt: Date
    public var finishedAt: Date?
    public var to: InstanceRef
    public var toAccountID: String
    public var toOrgID: String
    public var items: [Item]
    public var files: [FileBackup]
    public var createdDirs: [String]
    public var error: String?
    /// The last step journaled. A move that stopped part-way says where.
    public var step: String?
    /// Copies that were running before the move. Recovery reopens them.
    public var reopen: [InstanceRef]?

    public var isMove: Bool { kind == "move" }
    public var isCopy: Bool { kind == "copy" }
    public var backupFolderName: String { id }
    public var isUnfinished: Bool { state == .started }
    public var sessionCount: Int { items.count }
    public var title: String { items.count == 1 ? items[0].title : "\(items.count) sessions" }
    public var fromNames: [String] { Array(Set(items.map(\.from.name))).sorted() }
}

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var record: MoveRecord
    public var backupBytes: Int64
    public var id: String { record.id }
}

// MARK: Steps and errors

public enum MoveStep: Int, Sendable, CaseIterable {
    case quit, backup, moveFiles, lease, verify, reopen
    /// The four steps of a move that quits nothing.
    public static let plain: [MoveStep] = [.backup, .moveFiles, .lease, .verify]
    /// All six, for a move that quits and reopens apps.
    public static let orchestrated: [MoveStep] = allCases

    public var title: String {
        switch self {
        case .quit: "Quit apps"
        case .backup: "Back up"
        case .moveFiles: "Move session file"
        case .lease: "Transfer worktree lease"
        case .verify: "Verify"
        case .reopen: "Reopen apps"
        }
    }
    /// Steps 1 and 2 can be stopped. From step 3 a move is never left half-done.
    public var canStop: Bool { self == .quit || self == .backup }
}

public enum MoveStepState: Sendable { case running, done }

public enum MoveError: LocalizedError {
    case blocked([CheckRow])
    case notAllowed(String)
    case failedBeforeChanges(String)
    case rolledBack(id: String, reason: String)
    case rollbackFailed(id: String, reason: String)
    case noRecord(String)
    case didntQuit(String)
    case cancelled
    case cantFinish(String)
    case copyNotFound(String)
    /// Test hook: the process "died" right after this step was journaled.
    case simulatedCrash(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let rows): rows.first?.title ?? "Blocked."
        case .notAllowed(let n): "Moving into or out of \(n) is turned off."
        case .failedBeforeChanges(let r): "\(r) Nothing changed."
        case .rolledBack: "Move rolled back. Nothing changed."
        case .rollbackFailed(let id, let r): "Rollback didn't finish (\(r)). Backups for move \(id) are kept."
        case .noRecord(let id): "No move \(id) in History."
        case .didntQuit(let n): "\(n) didn't quit."
        case .cancelled: "Stopped. Nothing changed."
        case .cantFinish(let r): "This move can't be finished. \(r)"
        case .copyNotFound(let n): "Couldn't find the copy in \(n). It may have been deleted there."
        case .simulatedCrash(let s): "Simulated crash after \(s)."
        }
    }

    /// The underlying reason, for "Show Log".
    public var log: String {
        switch self {
        case .rolledBack(_, let r), .rollbackFailed(_, let r), .failedBeforeChanges(let r), .cantFinish(let r): r
        default: errorDescription ?? ""
        }
    }
}
