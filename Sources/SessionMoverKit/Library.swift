import Foundation

/// Everything Phase 1 knows, from one scan: copies, accounts, sessions and live state.
public struct Library: Sendable {
    public var instances: [InstanceScan]
    public var runningBundleIDs: Set<String>
    public var liveSessions: [LiveSession]
    public var scannedAt: Date
    /// "Copied" chips: from the app's settings, set by the scanner.
    public var copiedMarks: [CopiedMark] = []

    public init(instances: [InstanceScan] = [], runningBundleIDs: Set<String> = [], liveSessions: [LiveSession] = [], scannedAt: Date = .now) {
        self.instances = instances; self.runningBundleIDs = runningBundleIDs
        self.liveSessions = liveSessions; self.scannedAt = scannedAt
        index()
    }

    private var liveByHost: [String: LiveSession] = [:]
    private var liveByCli: [String: LiveSession] = [:]
    private var instanceIndex: [String: InstanceScan] = [:]

    private mutating func index() {
        for l in liveSessions {
            if let h = l.hostSessionId, liveByHost[h] == nil || l.isBusy { liveByHost[h] = l }
            if let c = l.cliSessionId, liveByCli[c] == nil || l.isBusy { liveByCli[c] = l }
        }
        instanceIndex = Dictionary(instances.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func scan(_ instanceID: String) -> InstanceScan? { instanceIndex[instanceID] }
    public func instance(_ id: String) -> Instance? { instanceIndex[id]?.instance }
    public func isRunning(_ instance: Instance) -> Bool { runningBundleIDs.contains(instance.bundleID) }

    public var allEntries: [SessionEntry] { instances.flatMap(\.entries) }

    // MARK: Live state

    /// Live process for this entry: matched by `hostSessionId == local_<id>`, then by Claude Code session id.
    public func live(for entry: SessionEntry) -> LiveSession? {
        if let l = liveByHost[entry.id] { return l }
        if let c = entry.summary?.cliSessionId, let l = liveByCli[c] { return l }
        return nil
    }
    public func isLive(_ e: SessionEntry) -> Bool { live(for: e) != nil }
    public func isBusy(_ e: SessionEntry) -> Bool { live(for: e)?.isBusy ?? false }

    public func hasBusySession(_ instance: Instance) -> Bool {
        scan(instance.id)?.entries.contains(where: isBusy) ?? false
    }

    // MARK: Per-entry state

    /// An account other than the one its copy is signed in to: Claude shows none of these sessions.
    public func isHidden(_ e: SessionEntry) -> Bool {
        guard let signedIn = scan(e.instanceID)?.signedInAccountID else { return false }
        return signedIn != e.accountID
    }

    public func needsAttention(_ e: SessionEntry) -> Bool {
        guard let s = e.summary else { return true }
        return s.isLimitError || s.folderExists == false
    }

    public func chips(for e: SessionEntry) -> [StateChip] {
        var chips: [StateChip] = []
        guard let s = e.summary else { return [.unreadable] }
        if let l = live(for: e) { chips.append(l.isBusy ? .busy : .running) }
        if s.isLimitError { chips.append(.limit(s.limitResets)) }
        if s.folderExists == false { chips.append(.folderMissing) }
        if s.isArchived { chips.append(.archived) }
        if !s.prNumbers.isEmpty { chips.append(.prs(s.prNumbers.count)) }
        if let m = copiedMarks.last(where: { $0.sourceID == e.id && $0.sourceBundleID == e.instanceID }) {
            chips.append(.copied(m.destName))
        }
        return chips.sorted { $0.priority < $1.priority }
    }

    // MARK: Scopes

    public func entries(in scope: Scope) -> [SessionEntry] {
        switch scope {
        case .all: return allEntries
        case .hidden: return allEntries.filter(isHidden)
        case .running: return allEntries.filter(isLive)
        case .needsAttention: return allEntries.filter(needsAttention)
        case .history: return []
        case .instance(let i): return scan(i)?.entries ?? []
        case .account(let i, let a): return scan(i)?.entries.filter { $0.accountID == a } ?? []
        case .org(let i, let a, let o): return scan(i)?.entries.filter { $0.accountID == a && $0.orgID == o } ?? []
        }
    }

    /// Sessions of one account id across every copy (for first-run naming).
    public func entries(forAccount a: String) -> [SessionEntry] { allEntries.filter { $0.accountID == a } }

    /// Every account id seen, with the copies it is signed in to now.
    public func accountIDs() -> [String] {
        var seen: [String] = []
        for i in instances { for a in i.accountIDs where !seen.contains(a) { seen.append(a) } }
        return seen
    }
    public func instancesSignedIn(to account: String) -> [Instance] {
        instances.filter { $0.signedInAccountID == account }.map(\.instance)
    }
}

/// What the user has selected in the sidebar.
public enum Scope: Hashable, Sendable {
    case all, hidden, running, needsAttention
    /// The History view (moves), not a list of sessions.
    case history
    case instance(String)
    case account(instance: String, account: String)
    case org(instance: String, account: String, org: String)

    public var isSmartList: Bool {
        switch self { case .all, .hidden, .running, .needsAttention: true; default: false }
    }
    public var instanceID: String? {
        switch self {
        case .instance(let i), .account(let i, _), .org(let i, _, _): i
        default: nil
        }
    }
}

public final class LibraryScanner: @unchecked Sendable {
    public let env: SMEnvironment
    private let running: RunningAppsProviding
    let isAlive: @Sendable (Int32) -> Bool
    private let reader = SessionTreeReader()

    public init(env: SMEnvironment, running: RunningAppsProviding = WorkspaceRunningApps(),
                isPIDAlive: @escaping @Sendable (Int32) -> Bool = LiveStateReader.defaultIsAlive) {
        self.env = env; self.running = running; self.isAlive = isPIDAlive
    }

    public func scan() -> Library {
        let instances = InstanceCatalog(env: env).load()
        var scans: [InstanceScan] = []
        var runningIDs = Set<String>()
        for inst in instances {
            let (orgs, err) = reader.read(instance: inst)
            scans.append(InstanceScan(instance: inst, signedInAccountID: SignedInAccount.read(dataDir: inst.dataURL),
                                      orgs: orgs, scanError: err))
            if running.isRunning(bundleID: inst.bundleID) { runningIDs.insert(inst.bundleID) }
        }
        let live = LiveStateReader.readSessions(in: env.claudeSessionsDir, isAlive: isAlive)
        var lib = Library(instances: scans, runningBundleIDs: runningIDs, liveSessions: live)
        lib.copiedMarks = SettingsStore(env: env).load().copied
        return lib
    }

    /// Folders worth watching: each copy's session tree, `~/.claude/sessions`, and the profile registry.
    public func watchPaths(for library: Library) -> [URL] {
        var p = library.instances.map { $0.instance.sessionsRoot }
        p.append(env.claudeSessionsDir)
        p.append(env.profilesJSON.deletingLastPathComponent())
        return p
    }
}
