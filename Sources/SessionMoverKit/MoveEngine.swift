import Foundation

/// Full moves of Claude Code sessions between copies and accounts, with a journal, backups and Undo.
/// The only code in this package that writes outside the app's own folder. Port of `spike/sm_move.py`.
///
/// `perform` never quits or opens a copy: when a copy a move touches is running, preflight blocks.
/// `performWithQuit` (MoveEngine+Orchestrate) quits the copies through the `AppControlling`, moves, and reopens them.
public final class MoveEngine: @unchecked Sendable {
    public static let prefsFile = "claude_desktop_config.json"
    public static let worktreesFile = "git-worktrees.json"
    public static let archiveIndex = "archived-sessions.idx"
    static let groupsPath = ["preferences", "epitaxyPrefs", "dframe-group-scopes"]

    public let env: SMEnvironment
    public var policy: WritePolicy
    public var formatGuard: FormatGuard
    public var labels: AccountLabels
    /// Test hook: called with a step name; returning true makes that step throw.
    /// Steps: backup, writeDestination, lease, group, idx, sideFiles, verify, deleteSource.
    public var injectFailure: (@Sendable (String) -> Bool)?
    /// Test hook: called right after a step is journaled; returning true "kills the process" there: the move stops
    /// with `MoveError.simulatedCrash` and leaves everything as it is. smctl's `SM_TEST_CRASH_AT` calls `exit(9)` from it.
    /// Steps: backup, writeDestination, group, idx, sideFiles, lease, verify, deleteSource.
    public var crashHook: (@Sendable (String) -> Bool)?
    /// Quits and reopens copies. Refuses any copy the write allowlist doesn't permit.
    public var appController: AppControlling
    /// How long to wait, after a quit, for the session processes of a quit copy to disappear.
    public var settleTimeout: TimeInterval = 8

    let running: RunningAppsProviding
    let realProcesses: RealProcessChecking
    let scanner: LibraryScanner

    public init(env: SMEnvironment,
                running: RunningAppsProviding = WorkspaceRunningApps(),
                realProcesses: RealProcessChecking = SystemRealProcesses(),
                policy: WritePolicy? = nil,
                formatGuard: FormatGuard = .standard,
                labels: AccountLabels = AccountLabels(),
                appController: AppControlling? = nil,
                isPIDAlive: @escaping @Sendable (Int32) -> Bool = LiveStateReader.defaultIsAlive) {
        self.env = env
        self.running = running
        self.realProcesses = realProcesses
        let effective = policy ?? WritePolicy.current(env: env)
        self.policy = effective
        self.appController = appController ?? SystemAppController(policy: effective, running: running, realProcesses: realProcesses)
        self.formatGuard = formatGuard
        self.labels = labels
        self.scanner = LibraryScanner(env: env, running: running, isPIDAlive: isPIDAlive)
    }

    /// Settings changed the allowlist: the engine and, when it is the system one, its app controller follow.
    public func updatePolicy(_ new: WritePolicy) {
        policy = new
        if appController is SystemAppController {
            appController = SystemAppController(policy: new, running: running, realProcesses: realProcesses)
        }
    }

    public var backupsDir: URL { env.settingsDir.appendingPathComponent("backups", isDirectory: true) }

    func isRunning(_ i: Instance) -> Bool {
        running.isRunning(bundleID: i.bundleID) || (i.appInstalled && realProcesses.hasRealProcess(appURL: i.appURL))
    }

    func isRunning(_ r: InstanceRef) -> Bool {
        running.isRunning(bundleID: r.bundleID) || realProcesses.hasRealProcess(appURL: URL(fileURLWithPath: r.appPath))
    }

    public func phrase(_ instance: String, account: String) -> String { "\(instance) · \(labels.phrase(account: account))" }

    // MARK: Entry rewrite

    /// Copies the entry, changing only what a move must: drops `cliBinaryPin`, nulls `remoteMcpServersConfig`
    /// across organizations, and clears a usage-limit error. Unknown keys survive. `changed` is false when
    /// nothing needed to change, in which case the original bytes are written as they are.
    static func rewriteEntry(_ entry: [String: Any], sameOrg: Bool) -> (entry: [String: Any], notes: [String], changed: Bool) {
        var e = entry
        var notes: [String] = []
        if e["cliBinaryPin"] != nil {
            e.removeValue(forKey: "cliBinaryPin")
            notes.append("cleared cliBinaryPin")
        }
        if !sameOrg, let v = e["remoteMcpServersConfig"], !(v is NSNull), !((v as? [Any])?.isEmpty ?? false) {
            e["remoteMcpServersConfig"] = NSNull()
            notes.append("cleared remoteMcpServersConfig (other organization)")
        }
        if let err = e["error"] as? String, err.range(of: "limit", options: .caseInsensitive) != nil {
            for k in ["error", "errorAt", "errorRows", "errorCategory"] { e.removeValue(forKey: k) }
            notes.append("cleared usage-limit error")
        }
        return (e, notes, !notes.isEmpty)
    }

    // MARK: Small readers

    func leaseNames(in dataDir: URL, sid: String) -> [String] {
        guard let wt = try? MoveFiles.readObject(dataDir.appendingPathComponent(Self.worktreesFile)),
              let trees = wt["worktrees"] as? [String: Any] else { return [] }
        return trees.compactMap { k, v in ((v as? [String: Any])?["leasedBy"] as? String) == sid ? k : nil }.sorted()
    }

    func groupAssignment(prefs: URL, scope: String, sid: String) -> String? {
        guard let p = try? MoveFiles.readObject(prefs) else { return nil }
        return MoveFiles.lookup(p, Self.groupsPath + [scope, "assignments", "code:\(sid)"]) as? String
    }

    func archiveIndexContains(_ folder: URL, _ sid: String) -> Bool? {
        guard let j = try? MoveFiles.readObject(folder.appendingPathComponent(Self.archiveIndex)) else { return nil }
        return (j["archived"] as? [String] ?? []).contains(sid)
    }

    static func tilde(_ p: String) -> String { SessionTreeReader.tilde(p) }

    // MARK: Preflight

    /// `library`: a recent scan to reuse (drag feedback); nil scans the disk now.
    /// `allowQuit`: an open copy is a warning ("They quit, then reopen after the move.") instead of a block, except
    /// when it has a busy session. `replace`: an entry already at the destination is replaced, after a backup.
    public func preflight(sessions: [SessionEntry], to dest: MoveDestination, library: Library? = nil,
                          allowQuit: Bool = false, replace: Bool = false) -> MovePlan {
        let lib = library ?? scanner.scan()
        guard let dstScan = lib.scan(dest.instanceID) else {
            return MovePlan(destination: dest, destinationInstance: nil, items: [], destinationPhrase: "", replace: replace)
        }
        let dst = dstScan.instance
        let dstAcct = dest.accountID ?? dstScan.signedInAccountID
        let movingKeys = Set(sessions.map(\.fileURL))
        var runCache: [String: Bool] = [:]
        func running(_ i: Instance) -> Bool {
            if let v = runCache[i.id] { return v }
            let v = isRunning(i); runCache[i.id] = v; return v
        }

        var items: [SessionPlan] = []
        var mustQuit: [Instance] = []
        for given in sessions {
            let key = given.fileURL.path
            var rows: [CheckRow] = []
            func add(_ k: CheckKind, _ s: CheckStatus, _ t: String, _ d: String? = nil) { rows.append(CheckRow(k, s, t, detail: d, session: key)) }

            guard let e = lib.allEntries.first(where: { $0.fileURL == given.fileURL }), let srcScan = lib.scan(e.instanceID) else {
                add(.state, .block, "\"\(given.displayTitle)\" isn't there any more.", "Rescan and try again.")
                items.append(SessionPlan(entry: given, source: dst, destination: dst, rows: rows, isDuplicate: false, leaseNames: []))
                continue
            }
            let src = srcScan.instance
            let title = e.displayTitle
            var plan = SessionPlan(entry: e, source: src, destination: dst, rows: [], isDuplicate: false, leaseNames: [])
            let sameCopy = src.id == dst.id
            let distinct = sameCopy ? [src] : [src, dst]

            guard let sum = e.summary else {
                add(.state, .block, "\(e.fileURL.lastPathComponent) isn't valid. It's left as it is.", e.readError)
                plan.rows = rows; items.append(plan); continue
            }

            // Write allowlist
            let off = distinct.filter { !policy.allows($0) }
            if !off.isEmpty {
                add(.allowlist, .block, "Moving into or out of \(Self.joinNames(off.map(\.name))) is turned off.",
                    off.count == 1 ? "Turn it on in Settings ▸ Moves." : "Turn them on in Settings ▸ Moves.")
            }

            // App versions
            var versionBlocked = false
            for i in distinct { if let m = formatGuard.blockMessage(for: i) { add(.version, .block, m, "Open a copy works on any version."); versionBlocked = true } }
            if !versionBlocked { add(.version, .pass, "Versions verified") }

            // Apps involved
            let open = distinct.filter(running)
            if open.isEmpty { add(.apps, .pass, "No apps need to quit") }
            else if !allowQuit { add(.apps, .block, "Quit \(Self.joinNames(open.map(\.name))) first.", "Session Mover doesn't quit apps unless you ask it to.") }
            else {
                for i in open where !mustQuit.contains(where: { $0.id == i.id }) { mustQuit.append(i) }
                let busy = open.compactMap { i -> (Instance, SessionEntry)? in
                    lib.scan(i.id)?.entries.first { $0.fileURL != e.fileURL && lib.isBusy($0) }.map { (i, $0) }
                }
                if let (i, b) = busy.first {
                    add(.apps, .block, "\(i.name) has a busy session: \"\(b.displayTitle)\". It can't quit now.",
                        "Wait for the turn to finish, or stop it in Claude.")
                } else {
                    add(.apps, .warn, open.count == 1 ? "\(open[0].name) is open. It quits, then reopens after the move."
                                                      : "\(Self.joinNames(open.map(\.name))) are open. They quit, then reopen after the move.")
                }
            }

            // Session state
            if let live = lib.live(for: e) {
                if live.isBusy { add(.state, .block, "\"\(title)\" is busy.", "Wait for the turn to finish, or stop it in Claude.") }
                else if running(src) { add(.state, .warn, "Open in \(src.name). Quitting closes it.") }
                else { add(.state, .block, "\"\(title)\" is open in a terminal.", "Close it there first.") }
            } else { add(.state, .pass, "Session isn't running") }

            // Other open sessions in the copies that quit (idle ones; a busy one blocks under Apps involved)
            let quitting = allowQuit ? open : (running(src) ? [src] : [])
            if !quitting.isEmpty {
                let others = quitting.flatMap { i in
                    (lib.scan(i.id)?.entries ?? []).filter { $0.fileURL != e.fileURL && !movingKeys.contains($0.fileURL) && lib.isLive($0) && !lib.isBusy($0) }
                        .map { (i, $0) }
                }
                if let (i, first) = others.first {
                    add(.others, .warn, others.count == 1 ? "\"\(first.displayTitle)\" is open in \(i.name). Quitting closes it."
                                                          : "\(others.count) other sessions are open in \(Self.joinNames(quitting.map(\.name))). Quitting closes them.")
                }
            }

            // Destination
            var dstOrg: String?
            if !dst.dataFolderExists {
                add(.destination, .block, "\(dst.name)'s data folder is missing.", Self.tilde(dst.dataURL.path))
            } else if let acct = dstAcct {
                plan.dstAccountID = acct
                let orgs = dstScan.orgIDs(in: acct)
                if let o = dest.orgID { dstOrg = o }
                else if orgs.isEmpty || orgs.contains(e.orgID) { dstOrg = e.orgID }
                else if orgs.count == 1 { dstOrg = orgs[0] }
                else {
                    // Several folders, none the session's own: empty ones don't count.
                    let counts = dstScan.orgs.filter { $0.accountID == acct }
                    let full = counts.filter { !$0.entries.isEmpty }
                    if full.count == 1 { dstOrg = full[0].orgID }
                    else {
                        plan.orgChoices = (full.isEmpty ? counts : full).map {
                            OrgChoice(orgID: $0.orgID, label: labels.display(org: $0.orgID), entryCount: $0.entries.count)
                        }
                    }
                }
                if let org = dstOrg {
                    plan.dstOrgID = org
                    let folder = dst.sessionsRoot.appendingPathComponent(acct).appendingPathComponent(org)
                    let url = folder.appendingPathComponent("\(e.id).json")
                    plan.dstFolder = folder; plan.dstURL = url
                    let here = phrase(dst.name, account: acct)
                    if sameCopy && folder.standardizedFileURL == e.fileURL.deletingLastPathComponent().standardizedFileURL {
                        add(.destination, .block, "Already in \(here)")
                    } else if FileManager.default.fileExists(atPath: url.path) {
                        plan.isDuplicate = true
                        if replace { add(.destination, .warn, "Replaces the entry already in \(here).", "It is backed up first, so Undo brings it back.") }
                        else { add(.destination, .block, "Already in \(here)") }
                    } else if !sameCopy, let clash = dstScan.entries.first(where: { $0.id == e.id }) {
                        add(.destination, .block, "Already in \(phrase(dst.name, account: clash.accountID))"); plan.isDuplicate = true
                    } else { add(.destination, .pass, "Not in \(here) yet") }
                } else {
                    add(.destination, .block, "\(dst.name) has several organizations in that account.", "Choose an organization below.")
                }
            } else {
                add(.destination, .block, "\(dst.name) isn't signed in to an account.", "Choose an account in \(dst.name).")
            }

            // Working folder
            if let cwd = sum.cwd, !cwd.isEmpty {
                if sum.folderExists == false { add(.folder, .warn, "Folder is missing. The session will ask for a different folder.", Self.tilde(cwd)) }
                else { add(.folder, .pass, "Working folder exists", Self.tilde(cwd)) }
            }

            // Worktree lease
            let leases = leaseNames(in: src.dataURL, sid: e.id)
            plan.leaseNames = leases
            if !sameCopy, let conflict = leases.compactMap({ n -> (String, String)? in
                guard let wt = try? MoveFiles.readObject(dst.dataURL.appendingPathComponent(Self.worktreesFile)),
                      let rec = (wt["worktrees"] as? [String: Any])?[n] as? [String: Any],
                      let by = rec["leasedBy"] as? String, by != e.id else { return nil }
                return (n, by)
            }).first {
                add(.lease, .block, "\(dst.name) already leases worktree \"\(conflict.0)\" to another session.", conflict.1)
            } else if !leases.isEmpty {
                add(.lease, .pass, sameCopy ? "Worktree lease stays with it" : "Worktree lease moves with it", leases.joined(separator: ", "))
            } else if sum.worktreePath != nil || sum.worktreeName != nil {
                add(.lease, .warn, "Lease not found. The worktree stays where it is.")
            } else { add(.lease, .pass, "No worktree") }

            // Organization
            if let org = dstOrg {
                if org == e.orgID { add(.org, .pass, "Same organization") }
                else { add(.org, .warn, "Different organization. Connectors, published artifacts and scheduled tasks stay behind.") }
            }

            // Usage-limit notice
            if sum.isLimitError { add(.limit, .warn, "The weekly-limit notice is cleared on move.") }

            // Linked sessions
            var linked: [String] = []
            for pid in [sum.spawnedFromID, sum.forkedFromID].compactMap({ $0 }) {
                if let p = srcScan.entries.first(where: { $0.id == pid }), !movingKeys.contains(p.fileURL) { linked.append(p.displayTitle) }
            }
            for o in srcScan.entries where o.fileURL != e.fileURL && !movingKeys.contains(o.fileURL) {
                if o.summary?.spawnedFromID == e.id || o.summary?.forkedFromID == e.id { linked.append(o.displayTitle) }
            }
            if !linked.isEmpty {
                add(.family, .warn, "Linked sessions stay behind.", linked.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ") + (linked.count > 3 ? " and \(linked.count - 3) more" : ""))
            }

            // Pinned across accounts
            if sum.isStarred, let acct = dstAcct, acct != e.accountID {
                add(.pinned, .warn, "Pinned sessions arrive unpinned in another account.", "Pins are kept per account.")
            }

            plan.rows = rows
            items.append(plan)
        }
        return MovePlan(destination: dest, destinationInstance: dst, items: items,
                        destinationPhrase: dstAcct.map { phrase(dst.name, account: $0) } ?? dst.name,
                        mustQuit: mustQuit, replace: replace)
    }

    static func joinNames(_ n: [String]) -> String {
        n.count <= 2 ? n.joined(separator: " and ") : n.dropLast().joined(separator: ", ") + " and " + n.last!
    }
}
