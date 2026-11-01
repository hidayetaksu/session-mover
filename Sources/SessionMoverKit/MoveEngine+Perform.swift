import Foundation

extension MoveEngine {
    /// Everything one session's move needs, read once before any file is touched. Also rebuilt from a journal
    /// to finish an interrupted move, so it holds paths and flags, not plan objects.
    struct Work {
        var sid: String
        var title: String
        var cliSessionId: String?
        var srcRef: InstanceRef
        var srcData: URL, dstData: URL
        var srcURL: URL, dstURL: URL, srcFolder: URL, dstFolder: URL
        var srcAcct: String, srcOrg: String, dstAcct: String, dstOrg: String
        var sameCopy: Bool
        var data: Data
        var dict: [String: Any]
        var leaseNames: [String]
        var moveGroup: Bool
        var idxSrc: Bool
        var idxDst: Bool
        var isArchived: Bool
        var waitingInput: [URL]
        var notes: URL?
        var srcPrefs: URL { srcData.appendingPathComponent(MoveEngine.prefsFile) }
        var dstPrefs: URL { dstData.appendingPathComponent(MoveEngine.prefsFile) }
        var srcWT: URL { srcData.appendingPathComponent(MoveEngine.worktreesFile) }
        var dstWT: URL { dstData.appendingPathComponent(MoveEngine.worktreesFile) }
        var finalData: Data = Data()
    }

    /// The open journal of a move in flight. Every step is written down before the next one starts.
    final class MoveRun {
        var record: MoveRecord
        let jpath: URL
        unowned let engine: MoveEngine
        init(record: MoveRecord, jpath: URL, engine: MoveEngine) { self.record = record; self.jpath = jpath; self.engine = engine }
        func write() throws { try engine.writeJournal(record, to: jpath) }
        /// Journals the step reached, then lets the test hook "kill" the process.
        func mark(_ step: String) throws {
            record.step = step
            try write()
            if engine.crashHook?(step) == true { throw MoveError.simulatedCrash(step) }
        }
        func fail(_ step: String) throws {
            if engine.injectFailure?(step) == true { throw MoveFiles.Failure(message: "injected failure at \(step)") }
        }
    }

    // MARK: Perform

    /// Moves every movable session of the plan, all or nothing. Rolls back from the backup on any failure
    /// once files start moving. Throws `MoveError`. Quits nothing: a running copy blocks (see `performWithQuit`).
    /// `cancelled` is polled while backing up; a stop there changes nothing.
    @discardableResult
    public func perform(_ plan: MovePlan, progress: (@Sendable (MoveStep, MoveStepState) -> Void)? = nil,
                        cancelled: (@Sendable () -> Bool)? = nil, reopenAfter: [InstanceRef]? = nil) throws -> MoveRecord {
        let fm = FileManager.default
        guard let dstInst = plan.destinationInstance, !plan.movable.isEmpty else {
            throw MoveError.blocked(plan.items.flatMap(\.blocks))
        }
        // Re-run the checks: the plan may be minutes old.
        let fresh = preflight(sessions: plan.movable.map(\.entry), to: plan.destination, replace: plan.replace)
        if fresh.items.isEmpty || !fresh.blocked.isEmpty { throw MoveError.blocked(fresh.items.flatMap(\.blocks)) }
        for p in fresh.items {
            for i in [p.source, p.destination] where !policy.allows(i) { throw MoveError.notAllowed(i.name) }
        }

        // Read everything first. Failures here change nothing.
        var works: [Work] = []
        do { works = try fresh.items.map(prepare) }
        catch { throw MoveError.failedBeforeChanges(error.localizedDescription) }

        // Journal and backups.
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let moveID = "\(f.string(from: now))-\(UUID().uuidString.prefix(6).lowercased())"
        let bdir = backupsDir.appendingPathComponent(moveID, isDirectory: true)
        let jpath = bdir.appendingPathComponent("journal.json")

        let record = MoveRecord(
            id: moveID, kind: "move", state: .started, createdAt: now, finishedAt: nil,
            to: InstanceRef(dstInst), toAccountID: works[0].dstAcct, toOrgID: works[0].dstOrg,
            items: works.map {
                MoveRecord.Item(sessionID: $0.sid, title: $0.title,
                                cliSessionId: $0.cliSessionId, from: $0.srcRef,
                                fromAccountID: $0.srcAcct, fromOrgID: $0.srcOrg, srcPath: $0.srcURL.path,
                                dstPath: $0.dstURL.path, srcSHA256: MoveFiles.sha256($0.data), dstSHA256: nil,
                                leases: $0.leaseNames, movedDirs: [])
            },
            files: [], createdDirs: [], error: nil, step: nil, reopen: reopenAfter)
        let run = MoveRun(record: record, jpath: jpath, engine: self)

        progress?(.backup, .running)
        do {
            try fm.createDirectory(at: bdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var seen = Set<String>()
            for url in works.flatMap(touchedFiles) where seen.insert(url.path).inserted {
                if cancelled?() == true { throw MoveError.cancelled }
                run.record.files.append(try backUp(url, index: run.record.files.count, into: bdir))
            }
            if cancelled?() == true { throw MoveError.cancelled }
            if injectFailure?("backup") == true { throw MoveFiles.Failure(message: "injected failure at backup") }
            try writeJournal(run.record, to: jpath)
        } catch {
            try? fm.removeItem(at: bdir)
            if let me = error as? MoveError, case .cancelled = me { throw me }
            throw MoveError.failedBeforeChanges("Couldn't back up (\(error.localizedDescription)).")
        }
        progress?(.backup, .done)

        do {
            try run.mark("backup")
            progress?(.moveFiles, .running)
            for (n, var w) in works.enumerated() {
                // Destination entry
                let (newEntry, _, changed) = Self.rewriteEntry(w.dict, sameOrg: w.srcOrg == w.dstOrg)
                w.finalData = changed ? try MoveFiles.encode(newEntry, pretty: false) : w.data
                run.record.createdDirs += try MoveFiles.makeDirs(w.dstFolder).map(\.path)
                try MoveFiles.writeAtomic(w.finalData, to: w.dstURL, mode: 0o600)
                try run.fail("writeDestination")
                run.record.items[n].dstSHA256 = MoveFiles.sha256(w.finalData)
                try run.mark("writeDestination")
                works[n] = w

                try applySideEffects(w, item: n, run: run)
            }
            progress?(.moveFiles, .done)

            // Worktree leases
            progress?(.lease, .running)
            for w in works where !w.sameCopy && !w.leaseNames.isEmpty { try transferLeases(w) }
            try run.fail("lease")
            try run.mark("lease")
            progress?(.lease, .done)

            // Read everything back, then and only then remove the sources.
            progress?(.verify, .running)
            try verifyDestinations(works)
            try run.fail("verify")
            try run.mark("verify")
            try removeSources(works, run: run)
            progress?(.verify, .done)

            run.record.state = .done
            run.record.step = "done"
            run.record.finishedAt = Date()
            try run.write()
            return run.record
        } catch let e as MoveError {
            if case .simulatedCrash = e { throw e }
            throw rollBackAfterFailure(e.localizedDescription, run: run)
        } catch {
            throw rollBackAfterFailure(error.localizedDescription, run: run)
        }
    }

    /// Restores from the backup and says so in the journal. Returns the error to throw.
    func rollBackAfterFailure(_ reason: String, run: MoveRun) -> MoveError {
        do {
            try restoreFiles(run.record)
            run.record.state = .rolledBack
            run.record.error = reason
            run.record.finishedAt = Date()
            try? run.write()
            return MoveError.rolledBack(id: run.record.id, reason: reason)
        } catch {
            run.record.error = "\(reason); rollback: \(error.localizedDescription)"
            try? run.write()
            return MoveError.rollbackFailed(id: run.record.id, reason: error.localizedDescription)
        }
    }

    func backUp(_ url: URL, index: Int, into bdir: URL) throws -> MoveRecord.FileBackup {
        var rec = MoveRecord.FileBackup(path: url.path, existed: FileManager.default.fileExists(atPath: url.path))
        if rec.existed {
            let data = try Data(contentsOf: url)
            rec.backup = String(format: "%02d-%@", index, url.lastPathComponent)
            try MoveFiles.writeAtomic(data, to: bdir.appendingPathComponent(rec.backup!), mode: 0o600)
            rec.mode = MoveFiles.mode(of: url).map(Int.init)
            rec.sha256 = MoveFiles.sha256(data)
        }
        return rec
    }

    /// Group membership, archive hints and side files of one session. Safe to run again after a crash:
    /// each piece looks at what is on disk and does only what is left.
    func applySideEffects(_ w: Work, item n: Int, run: MoveRun) throws {
        let fm = FileManager.default
        if w.moveGroup { try moveGroupMembership(w) }
        try run.fail("group")
        try run.mark("group")

        if w.idxSrc { try updateArchiveIndex(w.srcFolder, sid: w.sid, present: false) }
        if w.isArchived, w.idxDst { try updateArchiveIndex(w.dstFolder, sid: w.sid, present: true) }
        try run.fail("idx")
        try run.mark("idx")

        // Side files Claude deletes when the id isn't in the folder
        for p in w.waitingInput {
            let q = w.dstFolder.appendingPathComponent("waiting-input").appendingPathComponent(p.lastPathComponent)
            guard !fm.fileExists(atPath: q.path) else { continue }
            run.record.createdDirs += try MoveFiles.makeDirs(q.deletingLastPathComponent()).map(\.path)
            try fm.copyItem(at: p, to: q)
            run.record.items[n].movedDirs.append(.init(from: p.path, to: q.path, keepSource: false))
            try run.write()
        }
        if let notes = w.notes {
            let q = w.dstData.appendingPathComponent("side-session-notes").appendingPathComponent(w.sid)
            if !fm.fileExists(atPath: q.path) {
                run.record.createdDirs += try MoveFiles.makeDirs(q.deletingLastPathComponent()).map(\.path)
                try fm.copyItem(at: notes, to: q)
                run.record.items[n].movedDirs.append(.init(from: notes.path, to: q.path, keepSource: true))
                try run.write()
            }
        }
        try run.fail("sideFiles")
        try run.mark("sideFiles")
    }

    func verifyDestinations(_ works: [Work]) throws {
        for w in works {
            guard let back = try? Data(contentsOf: w.dstURL), back == w.finalData,
                  (try? JSONSerialization.jsonObject(with: back)) != nil else {
                throw MoveFiles.Failure(message: "The destination entry for \(w.sid) did not read back.")
            }
        }
    }

    func removeSources(_ works: [Work], run: MoveRun) throws {
        let fm = FileManager.default
        for w in works {
            if fm.fileExists(atPath: w.srcURL.path) { try fm.removeItem(at: w.srcURL) }
            try run.fail("deleteSource")
            try run.mark("deleteSource")
        }
        for item in run.record.items {
            for d in item.movedDirs where !d.keepSource { try? fm.removeItem(atPath: d.from) }
        }
    }

    // MARK: Prepare

    func prepare(_ sp: SessionPlan) throws -> Work {
        guard let dstFolder = sp.dstFolder, let dstURL = sp.dstURL, let dstAcct = sp.dstAccountID, let dstOrg = sp.dstOrgID else {
            throw MoveFiles.Failure(message: "No destination for \"\(sp.entry.displayTitle)\".")
        }
        let e = sp.entry
        let data = try Data(contentsOf: e.fileURL)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoveFiles.Failure(message: "\(e.fileURL.lastPathComponent) isn't valid.")
        }
        guard (dict["sessionId"] as? String) == e.id else {
            throw MoveFiles.Failure(message: "\(e.fileURL.lastPathComponent) has sessionId \((dict["sessionId"] as? String) ?? "none").")
        }
        let srcFolder = e.fileURL.deletingLastPathComponent()
        let sameCopy = sp.source.id == sp.destination.id
        let cli = (dict["cliSessionId"] as? String) ?? String(e.id.dropFirst("local_".count))
        let wiDir = srcFolder.appendingPathComponent("waiting-input")
        let wi = ((try? FileManager.default.contentsOfDirectory(atPath: wiDir.path)) ?? [])
            .filter { $0.hasPrefix(e.id) || (!cli.isEmpty && $0.hasPrefix(cli)) }.sorted()
            .map { wiDir.appendingPathComponent($0) }
        let notes = sp.source.dataURL.appendingPathComponent("side-session-notes").appendingPathComponent(e.id)
        var isDir: ObjCBool = false
        let hasNotes = !sameCopy && FileManager.default.fileExists(atPath: notes.path, isDirectory: &isDir) && isDir.boolValue

        let srcScope = "\(e.accountID)/\(e.orgID)"
        var w = Work(sid: e.id, title: e.displayTitle, cliSessionId: e.summary?.cliSessionId, srcRef: InstanceRef(sp.source),
                     srcData: sp.source.dataURL, dstData: sp.destination.dataURL, srcURL: e.fileURL, dstURL: dstURL,
                     srcFolder: srcFolder, dstFolder: dstFolder, srcAcct: e.accountID, srcOrg: e.orgID, dstAcct: dstAcct, dstOrg: dstOrg,
                     sameCopy: sameCopy, data: data, dict: dict, leaseNames: leaseNames(in: sp.source.dataURL, sid: e.id),
                     moveGroup: false, idxSrc: false, idxDst: false, isArchived: e.summary?.isArchived == true,
                     waitingInput: wi, notes: hasNotes ? notes : nil)
        w.moveGroup = groupAssignment(prefs: w.srcPrefs, scope: srcScope, sid: e.id) != nil
        w.idxSrc = archiveIndexContains(srcFolder, e.id) == true
        w.idxDst = archiveIndexContains(dstFolder, e.id) == false
        return w
    }

    /// Exactly the files this move will write or delete, so a restore never touches anything else.
    func touchedFiles(_ w: Work) -> [URL] {
        var f = [w.srcURL, w.dstURL]
        if !w.sameCopy && !w.leaseNames.isEmpty { f += [w.srcWT, w.dstWT] }
        if w.idxSrc { f.append(w.srcFolder.appendingPathComponent(Self.archiveIndex)) }
        if w.idxDst && w.isArchived { f.append(w.dstFolder.appendingPathComponent(Self.archiveIndex)) }
        if w.moveGroup { f += w.sameCopy ? [w.srcPrefs] : [w.srcPrefs, w.dstPrefs] }
        return f
    }

    // MARK: Pieces of a move

    func transferLeases(_ w: Work) throws {
        var src = try MoveFiles.readObject(w.srcWT) ?? [:]
        var dst = try MoveFiles.readObject(w.dstWT) ?? [:]
        var srcTrees = src["worktrees"] as? [String: Any] ?? [:]
        var dstTrees = dst["worktrees"] as? [String: Any] ?? [:]
        let names = srcTrees.compactMap { k, v in ((v as? [String: Any])?["leasedBy"] as? String) == w.sid ? k : nil }
        guard !names.isEmpty else { return }
        for n in names { dstTrees[n] = srcTrees.removeValue(forKey: n) }
        if dst["schemaVersion"] == nil { dst["schemaVersion"] = src["schemaVersion"] ?? 2 }
        src["worktrees"] = srcTrees
        dst["worktrees"] = dstTrees
        try MoveFiles.writeAtomic(MoveFiles.encode(dst, pretty: true), to: w.dstWT, mode: 0o600)
        try MoveFiles.writeAtomic(MoveFiles.encode(src, pretty: true), to: w.srcWT, mode: 0o600)
    }

    /// Group membership is local to each copy, keyed `<account>/<org>`. Moves the assignment, and the
    /// group's definition when the destination scope lacks it.
    func moveGroupMembership(_ w: Work) throws {
        let key = "code:\(w.sid)"
        let srcScope = "\(w.srcAcct)/\(w.srcOrg)", dstScope = "\(w.dstAcct)/\(w.dstOrg)"
        var sp = try MoveFiles.readObject(w.srcPrefs) ?? [:]
        let base = Self.groupsPath
        guard let gid = MoveFiles.lookup(sp, base + [srcScope, "assignments", key]) as? String else { return }
        let groups = MoveFiles.lookup(sp, base + [srcScope, "groups"]) as? [[String: Any]] ?? []
        let group = groups.first { ($0["id"] as? String) == gid }

        MoveFiles.mutate(&sp, path: ArraySlice(base + [srcScope])) { s in
            var a = s["assignments"] as? [String: Any] ?? [:]; a.removeValue(forKey: key); s["assignments"] = a
            if var o = s["order"] as? [String: Any], let list = o[gid] as? [String] {
                o[gid] = list.filter { $0 != key }; s["order"] = o
            }
        }
        var dp = w.sameCopy ? sp : (try MoveFiles.readObject(w.dstPrefs) ?? [:])
        MoveFiles.mutate(&dp, path: ArraySlice(base + [dstScope])) { d in
            var g = d["groups"] as? [[String: Any]] ?? []
            if let group, !g.contains(where: { ($0["id"] as? String) == gid }) { g.append(group) }
            d["groups"] = g
            var a = d["assignments"] as? [String: Any] ?? [:]; a[key] = gid; d["assignments"] = a
            var o = d["order"] as? [String: Any] ?? [:]
            var list = o[gid] as? [String] ?? []
            if !list.contains(key) { list.append(key) }
            o[gid] = list; d["order"] = o
        }
        let mode = MoveFiles.mode(of: w.dstPrefs) ?? 0o600
        try MoveFiles.writeAtomic(MoveFiles.encode(dp, pretty: true), to: w.dstPrefs, mode: mode)
        if !w.sameCopy {
            try MoveFiles.writeAtomic(MoveFiles.encode(sp, pretty: true), to: w.srcPrefs, mode: MoveFiles.mode(of: w.srcPrefs) ?? 0o600)
        }
    }

    /// `archived-sessions.idx` is `{"v":1,"archived":[sorted ids]}`, a load-order hint. Absent file: nothing to do.
    func updateArchiveIndex(_ folder: URL, sid: String, present: Bool) throws {
        let url = folder.appendingPathComponent(Self.archiveIndex)
        guard let j = try MoveFiles.readObject(url) else { return }
        var ids = Set(j["archived"] as? [String] ?? [])
        guard ids.contains(sid) != present else { return }
        if present { ids.insert(sid) } else { ids.remove(sid) }
        let list = try JSONSerialization.data(withJSONObject: ids.sorted(), options: [.withoutEscapingSlashes])
        let v = (j["v"] as? NSNumber)?.intValue ?? 1
        try MoveFiles.writeAtomic(Data("{\"v\":\(v),\"archived\":".utf8) + list + Data("}".utf8), to: url, mode: 0o600)
    }

    // MARK: Journal and restore

    func writeJournal(_ record: MoveRecord, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .millisecondsSince1970
        try MoveFiles.writeAtomic(enc.encode(record), to: url, mode: 0o600)
    }

    /// Puts every file the move touched back from the backup, byte for byte, removes what didn't exist before,
    /// and moves side files back. Idempotent: safe to run twice.
    func restoreFiles(_ record: MoveRecord) throws {
        let fm = FileManager.default
        let bdir = backupsDir.appendingPathComponent(record.backupFolderName, isDirectory: true)
        var problems: [String] = []
        for f in record.files {
            let url = URL(fileURLWithPath: f.path)
            do {
                if f.existed, let name = f.backup {
                    let data = try Data(contentsOf: bdir.appendingPathComponent(name))
                    _ = try MoveFiles.makeDirs(url.deletingLastPathComponent())
                    try MoveFiles.writeAtomic(data, to: url, mode: mode_t(f.mode ?? 0o600))
                } else if fm.fileExists(atPath: f.path) {
                    try fm.removeItem(at: url)
                }
            } catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        for item in record.items {
            for d in item.movedDirs.reversed() {
                do {
                    let toExists = fm.fileExists(atPath: d.to), fromExists = fm.fileExists(atPath: d.from)
                    if toExists && !fromExists && !d.keepSource {
                        _ = try MoveFiles.makeDirs(URL(fileURLWithPath: d.from).deletingLastPathComponent())
                        try fm.moveItem(atPath: d.to, toPath: d.from)
                    } else if toExists { try fm.removeItem(atPath: d.to) }
                } catch { problems.append("\((d.to as NSString).lastPathComponent): \(error.localizedDescription)") }
            }
        }
        for dir in record.createdDirs.reversed() {
            if let left = try? fm.contentsOfDirectory(atPath: dir), left.isEmpty { try? fm.removeItem(atPath: dir) }
        }
        if !problems.isEmpty { throw MoveFiles.Failure(message: problems.joined(separator: "; ")) }
    }
}
