import Foundation

/// A plan to open a copy of a session in another copy of Claude (the deep link). Nothing is written by us.
public struct CopyPlan: Sendable {
    public var entry: SessionEntry
    public var source: Instance
    public var destination: Instance?
    public var dstAccountID: String?
    public var destinationPhrase: String
    public var rows: [CheckRow]
    public var isBlocked: Bool { rows.contains { $0.status == .block } }
    public var blocks: [CheckRow] { rows.filter { $0.status == .block } }
    public var warnings: [CheckRow] { rows.filter { $0.status == .warn } }
    public var canCopy: Bool { destination != nil && !isBlocked }
}

extension MoveEngine {
    // MARK: Plan

    /// Open a copy: `claude://resume?session=<cliSessionId>` aimed at the destination copy. Works while apps run,
    /// so nothing here asks anything to quit. The copy lands in the account the destination is signed in to.
    public func copyPlan(entry given: SessionEntry, to dest: MoveDestination, library: Library? = nil) -> CopyPlan {
        let lib = library ?? scanner.scan()
        guard let dstScan = lib.scan(dest.instanceID) else {
            return CopyPlan(entry: given, source: Self.placeholder, destination: nil, destinationPhrase: "", rows: [])
        }
        let dst = dstScan.instance
        let e = lib.allEntries.first { $0.fileURL == given.fileURL } ?? given
        let src = lib.instance(e.instanceID) ?? dst
        var rows: [CheckRow] = []
        func add(_ k: CheckKind, _ s: CheckStatus, _ t: String, _ d: String? = nil) { rows.append(CheckRow(k, s, t, detail: d, session: e.fileURL.path)) }

        guard let sum = e.summary else {
            add(.state, .block, "\(e.fileURL.lastPathComponent) isn't valid. It's left as it is.", e.readError)
            return CopyPlan(entry: e, source: src, destination: dst, destinationPhrase: dst.name, rows: rows)
        }
        if !policy.allows(dst) { add(.allowlist, .block, "Opening a copy in \(dst.name) is turned off.") }
        if sum.cliSessionId.flatMap({ CopyLauncher.resumeURL(cliSessionId: $0) }) == nil {
            add(.state, .block, "\"\(e.displayTitle)\" has no Claude Code id to open.")
        }
        if !dst.appInstalled { add(.destination, .block, "\(dst.name) isn't installed in Applications.") }

        let acct = dstScan.signedInAccountID
        let phraseAcct = dest.accountID ?? acct
        let destPhrase = phraseAcct.map { phrase(dst.name, account: $0) } ?? dst.name
        if let acct {
            if let want = dest.accountID, want != acct {
                add(.destination, .block, "\(dst.name) is signed in to a different account.", "A copy opens in the account \(dst.name) is signed in to. Switch accounts there first.")
            } else if dst.id == src.id && acct == e.accountID {
                add(.destination, .block, "Already in \(phrase(dst.name, account: acct))")
            } else {
                add(.destination, .pass, "Opens in \(phrase(dst.name, account: acct))")
            }
        } else {
            add(.destination, .block, "\(dst.name) isn't signed in to an account.", "Choose an account in \(dst.name).")
        }
        // A copy of this session may already be there (same history, another id).
        if let cli = sum.cliSessionId, let clash = dstScan.entries.first(where: { $0.fileURL != e.fileURL && $0.summary?.cliSessionId == cli }) {
            add(.family, .warn, "A copy of this session is already in \(phrase(dst.name, account: clash.accountID)).", "Opening another makes a second one.")
        }
        if let cwd = sum.cwd, !cwd.isEmpty {
            if sum.folderExists == false { add(.folder, .warn, "The copy will ask for a different folder.", Self.tilde(cwd)) }
            else { add(.folder, .pass, "Working folder exists", Self.tilde(cwd)) }
        }
        if lib.isLive(e) { add(.state, .warn, "\"\(e.displayTitle)\" is open in \(src.name). Don't run both at once.") }
        return CopyPlan(entry: e, source: src, destination: dst, dstAccountID: acct, destinationPhrase: destPhrase, rows: rows)
    }

    private static var placeholder: Instance {
        Instance(name: "", slug: nil, bundleID: "", appURL: URL(fileURLWithPath: "/"), dataURL: URL(fileURLWithPath: "/"), accentHex: "", iconName: "",
                 version: nil, kind: nil, origin: .discovered, appInstalled: false, dataFolderExists: false)
    }

    // MARK: Open

    /// Sends the deep link to the destination copy, then journals the copy in History (kind "copy", no backups
    /// needed: nothing of ours was written). Returns the record; the caller marks the source row "Copied".
    @MainActor
    public func performCopy(_ plan: CopyPlan, launcher: CopyLauncher = CopyLauncher()) async throws -> MoveRecord {
        guard let dst = plan.destination, !plan.isBlocked else { throw MoveError.blocked(plan.blocks) }
        guard policy.allows(dst) else { throw MoveError.notAllowed(dst.name) }
        let e = plan.entry
        try await launcher.openCopy(e, in: dst)
        return try journalCopy(plan, destination: dst)
    }

    func journalCopy(_ plan: CopyPlan, destination dst: Instance) throws -> MoveRecord {
        let e = plan.entry
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let id = "\(f.string(from: now))-\(UUID().uuidString.prefix(6).lowercased())"
        let bdir = backupsDir.appendingPathComponent(id, isDirectory: true)
        let acct = plan.dstAccountID ?? ""
        let record = MoveRecord(
            id: id, kind: "copy", state: .done, createdAt: now, finishedAt: now,
            to: InstanceRef(dst), toAccountID: acct, toOrgID: "",
            items: [MoveRecord.Item(sessionID: e.id, title: e.displayTitle, cliSessionId: e.summary?.cliSessionId,
                                    from: InstanceRef(plan.source), fromAccountID: e.accountID, fromOrgID: e.orgID,
                                    srcPath: e.fileURL.path, dstPath: "", srcSHA256: MoveFiles.sha256(of: e.fileURL) ?? "",
                                    dstSHA256: nil, leases: [], movedDirs: [])],
            files: [], createdDirs: [], error: nil, step: "opened", reopen: nil)
        try FileManager.default.createDirectory(at: bdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeJournal(record, to: bdir.appendingPathComponent("journal.json"))
        return record
    }

    /// The "Copied" chip for a journaled copy.
    public func copyMark(for record: MoveRecord) -> CopiedMark? {
        guard record.isCopy, let i = record.items.first else { return nil }
        return CopiedMark(sourceID: i.sessionID, sourceBundleID: i.from.bundleID, destBundleID: record.to.bundleID,
                          destName: record.to.name, createdAt: record.createdAt, moveID: record.id)
    }

    // MARK: Archive the copy (Undo of a copy)

    /// Entries in the destination with the copied session's Claude Code id that appeared after the copy was opened.
    func copyEntries(for record: MoveRecord) -> [SessionEntry] {
        guard let item = record.items.first, let cli = item.cliSessionId else { return [] }
        let lib = scanner.scan()
        let since = record.createdAt.addingTimeInterval(-5)
        return (lib.scan(record.to.bundleID)?.entries ?? []).filter { e in
            // Claude gives an imported copy the source's own local id, so only the source file itself is excluded.
            guard e.fileURL.standardizedFileURL.path != URL(fileURLWithPath: item.srcPath).standardizedFileURL.path,
                  e.summary?.cliSessionId == cli else { return false }
            let made = (try? FileManager.default.attributesOfItem(atPath: e.fileURL.path))?[.creationDate] as? Date
            return (made.map { $0 >= since } ?? false) || (e.summary?.createdAt.map { $0 >= since } ?? false)
        }
    }

    func copyRestorePlan(_ record: MoveRecord, allowQuit: Bool) -> RestorePlan {
        var rows: [CheckRow] = []
        func add(_ k: CheckKind, _ s: CheckStatus, _ t: String, _ d: String? = nil) { rows.append(CheckRow(k, s, t, detail: d)) }
        let to = record.to
        if record.state == .undone { add(.state, .block, "The copy is already archived.") }
        if !policy.allows(slug: to.slug) { add(.allowlist, .block, "Moving into or out of \(to.name) is turned off.") }
        rows.append(appsRow(open: isRunning(to) ? [to] : [], allowQuit: allowQuit, then: "archive", ignoring: []))
        if record.state != .undone {
            let found = copyEntries(for: record)
            if found.isEmpty { add(.destination, .block, "Couldn't find the copy in \(to.name).", "It may have been deleted there.") }
            else {
                let lib = scanner.scan()
                if let busy = found.first(where: { lib.isBusy($0) }) { add(.state, .block, "\"\(busy.displayTitle)\" is busy.", "Wait for the turn to finish, or stop it in Claude.") }
                else if found.contains(where: { lib.isLive($0) }) { add(.state, .warn, "The copy is open in \(to.name). Quitting closes it.") }
                else { add(.destination, .pass, "Copy found in \(to.name)") }
            }
        }
        add(.family, .pass, "The copy is archived, not deleted.", "Anything said in it stays.")
        return RestorePlan(record: record, rows: rows)
    }

    /// Sets `isArchived` on the copy in the destination and lists it in `archived-sessions.idx`. Never deletes.
    /// The files are backed up into the copy's journal first. The destination copy must be quit.
    func archiveCopy(_ current: MoveRecord) throws -> MoveRecord {
        let fm = FileManager.default
        let found = copyEntries(for: current)
        guard !found.isEmpty else { throw MoveError.copyNotFound(current.to.name) }
        var r = current
        let bdir = backupsDir.appendingPathComponent(r.backupFolderName, isDirectory: true)
        do {
            try fm.createDirectory(at: bdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for e in found {
                let folder = e.fileURL.deletingLastPathComponent()
                for url in [e.fileURL, folder.appendingPathComponent(Self.archiveIndex)] where !r.files.contains(where: { $0.path == url.path }) {
                    r.files.append(try backUp(url, index: r.files.count, into: bdir))
                }
            }
            try writeJournal(r, to: journalURL(r))
            for e in found {
                guard var dict = try MoveFiles.readObject(e.fileURL) else { continue }
                if dict["isArchived"] as? Bool != true {
                    dict["isArchived"] = true
                    let mode = MoveFiles.mode(of: e.fileURL) ?? 0o600
                    try MoveFiles.writeAtomic(MoveFiles.encode(dict, pretty: false), to: e.fileURL, mode: mode)
                }
                try updateArchiveIndex(e.fileURL.deletingLastPathComponent(), sid: e.id, present: true)
            }
        } catch {
            throw MoveError.rollbackFailed(id: r.id, reason: error.localizedDescription)
        }
        r.items[0].dstPath = found[0].fileURL.path
        r.state = .undone
        r.step = "archived"
        r.finishedAt = Date()
        try writeJournal(r, to: journalURL(r))
        return r
    }
}
