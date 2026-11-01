import Foundation

public struct RestorePlan: Sendable {
    public var record: MoveRecord
    public var rows: [CheckRow]
    public var isBlocked: Bool { rows.contains { $0.status == .block } }
    public var blocks: [CheckRow] { rows.filter { $0.status == .block } }
}

extension MoveEngine {
    // MARK: History

    /// Every move that left a journal, newest first.
    public func history() -> [HistoryEntry] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [HistoryEntry] = []
        for d in dirs {
            guard let r = readRecord(folder: d) else { continue }
            out.append(HistoryEntry(record: r, backupBytes: Self.folderSize(d)))
        }
        return out.sorted { ($0.record.createdAt, $0.id) > ($1.record.createdAt, $1.id) }
    }

    public func record(id: String) -> MoveRecord? {
        guard !id.contains("/"), !id.isEmpty else { return nil }
        return readRecord(folder: backupsDir.appendingPathComponent(id, isDirectory: true))
    }

    func readRecord(folder: URL) -> MoveRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("journal.json")) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return try? dec.decode(MoveRecord.self, from: data)
    }

    static func folderSize(_ url: URL) -> Int64 {
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = en?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    /// Deletes the backups of finished moves, which makes them impossible to restore. Unfinished moves stay.
    /// Returns how many moves were removed.
    @discardableResult
    public func emptyHistory() throws -> Int {
        var n = 0
        for h in history() where h.record.state != .started {
            try FileManager.default.removeItem(at: backupsDir.appendingPathComponent(h.record.backupFolderName, isDirectory: true))
            n += 1
        }
        return n
    }

    // MARK: Restore (Undo)

    /// The checks before a restore: copies quit, session not busy where it is now, and the source doesn't
    /// hold a newer entry with that id.
    /// `allowQuit`: open copies are a warning ("They quit, then reopen after the restore.") instead of a block,
    /// unless one has a busy session.
    public func restorePlan(for record: MoveRecord, allowQuit: Bool = false) -> RestorePlan {
        if record.isCopy { return copyRestorePlan(record, allowQuit: allowQuit) }
        var rows: [CheckRow] = []
        func add(_ k: CheckKind, _ s: CheckStatus, _ t: String, _ d: String? = nil) { rows.append(CheckRow(k, s, t, detail: d)) }
        let fm = FileManager.default

        switch record.state {
        case .undone: add(.state, .block, "Already restored.")
        case .rolledBack: add(.state, .block, "This move was rolled back. There is nothing to restore.")
        case .started, .done: break
        }

        var refs = [record.to]
        for i in record.items where !refs.contains(where: { $0.bundleID == i.from.bundleID }) { refs.append(i.from) }
        let off = refs.filter { !policy.allows(slug: $0.slug) }
        if !off.isEmpty {
            add(.allowlist, .block, "Moving into or out of \(Self.joinNames(off.map(\.name))) is turned off.",
                off.count == 1 ? "Turn it on in Settings ▸ Moves." : "Turn them on in Settings ▸ Moves.")
        }

        let open = refs.filter { isRunning($0) }
        rows.append(appsRow(open: open, allowQuit: allowQuit, then: "restore", ignoring: Set(record.items.map(\.sessionID))))

        let live = LiveStateReader.readSessions(in: env.claudeSessionsDir, isAlive: scanner.isAlive)
        for item in record.items {
            let l = live.first { $0.hostSessionId == item.sessionID || ($0.cliSessionId != nil && $0.cliSessionId == item.cliSessionId) }
            if let l, l.isBusy { add(.state, .block, "\"\(item.title)\" is busy.", "Wait for the turn to finish, or stop it in Claude.") }
            else if l != nil { add(.state, .warn, "\"\(item.title)\" is open in a terminal.") }

            if fm.fileExists(atPath: item.srcPath), MoveFiles.sha256(of: URL(fileURLWithPath: item.srcPath)) != item.srcSHA256 {
                add(.destination, .block, "\(item.from.name) holds a newer entry for \"\(item.title)\".", "Restoring would replace it.")
            }
            if record.state == .done {
                let now = MoveFiles.sha256(of: URL(fileURLWithPath: item.dstPath))
                if now != item.dstSHA256 {
                    add(.state, .warn, "\"\(item.title)\" changed after the move.",
                        now == nil ? "It is gone from \(record.to.name)." : "Restore drops those changes to the entry.")
                }
            }
        }
        add(.family, .pass, "Anything said since the move stays.", "History isn't part of the restore.")
        return RestorePlan(record: record, rows: rows)
    }

    /// The Apps row for a restore, finish or archive: pass, warn (they quit and reopen) or block (still open,
    /// or a busy session that can't be interrupted).
    func appsRow(open: [InstanceRef], allowQuit: Bool, then verb: String, ignoring: Set<String>) -> CheckRow {
        if open.isEmpty { return CheckRow(.apps, .pass, "No apps need to quit") }
        let names = Self.joinNames(open.map(\.name))
        guard allowQuit else { return CheckRow(.apps, .block, "Quit \(names) first.", detail: "Session Mover doesn't quit apps unless you ask it to.") }
        let lib = scanner.scan()
        for r in open {
            if let busy = lib.scan(r.bundleID)?.entries.first(where: { !ignoring.contains($0.id) && lib.isBusy($0) }) {
                return CheckRow(.apps, .block, "\(r.name) has a busy session: \"\(busy.displayTitle)\". It can't quit now.",
                                detail: "Wait for the turn to finish, or stop it in Claude.")
            }
        }
        return CheckRow(.apps, .warn, open.count == 1 ? "\(names) is open. It quits, then reopens after the \(verb)."
                                                       : "\(names) are open. They quit, then reopen after the \(verb).")
    }

    /// Puts every file the move touched back as it was, from the journal's backup. For a copy, archives the copy.
    /// Quits nothing: copies must already be quit (see `undoWithQuit`).
    @discardableResult
    public func undo(_ record: MoveRecord) throws -> MoveRecord {
        guard let current = self.record(id: record.id) else { throw MoveError.noRecord(record.id) }
        let plan = restorePlan(for: current)
        if plan.isBlocked { throw MoveError.blocked(plan.blocks) }
        if current.isCopy { return try archiveCopy(current) }
        var r = current
        do { try restoreFiles(r) }
        catch { throw MoveError.rollbackFailed(id: r.id, reason: error.localizedDescription) }
        r.state = r.state == .started ? .rolledBack : .undone
        r.finishedAt = Date()
        try writeJournal(r, to: backupsDir.appendingPathComponent(r.backupFolderName).appendingPathComponent("journal.json"))
        return r
    }
}
