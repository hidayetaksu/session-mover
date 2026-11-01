import Foundation

/// Quit & Move: quit the copies a move touches, move, reopen them. Also recovery of unfinished moves.
extension MoveEngine {
    // MARK: Orchestration

    /// 1 Quit (only when a copy is open), then `body`, then 6 Reopen (only when something was quit). A copy that doesn't quit changes nothing: the ones already quit are
    /// reopened. Never force-quits. `precheck` runs before anything is quit; `settle` after, retried until
    /// `settleTimeout` so a session process still shutting down has time to go.
    func orchestrate(copies: [InstanceRef], reopen: Bool, cancel: CancelToken?, alsoReopen: [InstanceRef] = [],
                     progress: (@Sendable (MoveStep, MoveStepState) -> Void)?,
                     precheck: () -> [CheckRow] = { [] }, settle: () -> [CheckRow],
                     body: () throws -> MoveRecord) throws -> MoveOutcome {
        var seen = Set<String>()
        let refs = copies.filter { seen.insert($0.bundleID).inserted }
        for r in refs where !policy.allows(slug: r.slug) { throw MoveError.notAllowed(r.name) }
        let blocks = precheck()
        if !blocks.isEmpty { throw MoveError.blocked(blocks) }

        let open = refs.filter { isRunning($0) }
        var quit: [InstanceRef] = []
        let isCancelled: @Sendable () -> Bool = { cancel?.isCancelled ?? false }

        /// Everything that went down because of us (or was running before a crash) and isn't up now.
        func reopenAll() -> [InstanceRef] {
            var failed: [InstanceRef] = []
            var done = Set<String>()
            for r in quit + alsoReopen where done.insert(r.bundleID).inserted && !isRunning(r) {
                do { try appController.reopen(r) } catch { failed.append(r) }
            }
            return failed
        }

        if !open.isEmpty { progress?(.quit, .running) }
        do {
            for r in open {
                quit.append(r)
                try appController.quit(r, cancelled: isCancelled)
            }
            if isCancelled() { throw AppControlError.cancelled }
        } catch {
            _ = reopenAll()
            switch error as? AppControlError {
            case .didntQuit(let n)?: throw MoveError.didntQuit(n)
            case .cancelled?: throw MoveError.cancelled
            case .notAllowed(let n)?: throw MoveError.notAllowed(n)
            default: throw error
            }
        }
        // The post-quit check from the spike: nothing of ours is still running, nobody is busy.
        var left = settle()
        let deadline = Date().addingTimeInterval(settleTimeout)
        while !left.isEmpty && Date() < deadline && !isCancelled() {
            Thread.sleep(forTimeInterval: 0.5)
            left = settle()
        }
        if !left.isEmpty {
            _ = reopenAll()
            throw MoveError.blocked(left)
        }
        if isCancelled() { _ = reopenAll(); throw MoveError.cancelled }
        if !open.isEmpty { progress?(.quit, .done) }

        let record: MoveRecord
        do { record = try body() }
        catch let e as MoveError {
            switch e {
            case .rollbackFailed, .simulatedCrash: throw e   // leave the apps closed: the journal needs a look first
            default: _ = reopenAll(); throw e
            }
        } catch { _ = reopenAll(); throw error }

        var failed: [InstanceRef] = []
        if reopen && !(quit.isEmpty && alsoReopen.isEmpty) {
            progress?(.reopen, .running)
            failed = reopenAll()
            progress?(.reopen, .done)
        }
        return MoveOutcome(record: record, quit: quit, reopenFailed: failed)
    }

    /// The copies a record touches: where it went, and every place it came from.
    func copies(of record: MoveRecord) -> [InstanceRef] {
        var refs = [record.to]
        for i in record.items where !refs.contains(where: { $0.bundleID == i.from.bundleID }) { refs.append(i.from) }
        return refs
    }

    // MARK: Quit & Move

    /// A full move that quits both copies first and reopens them after (`reopen`). The plan should come from
    /// `preflight(..., allowQuit: true)`. Steps: 1 Quit, 2 Back up, 3 Move session file, 4 Lease, 5 Verify, 6 Reopen.
    /// `cancel` stops it during steps 1 and 2 only.
    @discardableResult
    public func performWithQuit(_ plan: MovePlan, reopen: Bool = true, cancel: CancelToken? = nil,
                                progress: (@Sendable (MoveStep, MoveStepState) -> Void)? = nil) throws -> MoveOutcome {
        guard let dst = plan.destinationInstance, !plan.movable.isEmpty else {
            throw MoveError.blocked(plan.items.flatMap(\.blocks))
        }
        let entries = plan.movable.map(\.entry)
        let dest = plan.destination
        let replace = plan.replace
        var refs = [InstanceRef(dst)]
        for s in plan.movable where !refs.contains(where: { $0.bundleID == s.source.bundleID }) { refs.append(InstanceRef(s.source)) }
        let wasOpen = refs.filter { isRunning($0) }
        return try orchestrate(
            copies: refs, reopen: reopen, cancel: cancel, progress: progress,
            precheck: { self.preflight(sessions: entries, to: dest, allowQuit: true, replace: replace).items.flatMap(\.blocks) },
            settle: { self.preflight(sessions: entries, to: dest, replace: replace).items.flatMap(\.blocks) },
            body: {
                try self.perform(plan, progress: { step, state in progress?(step, state) },
                                 cancelled: { cancel?.isCancelled ?? false }, reopenAfter: wasOpen)
            })
    }

    // MARK: Recovery

    /// Moves a crash or power loss left unfinished, newest first.
    public func recoverableMoves() -> [MoveRecord] {
        history().map(\.record).filter { $0.state == .started && $0.isMove }
    }

    /// nil when `finish` can complete the move. For each session: its destination entry reads back as journaled,
    /// or it hadn't been written yet and the source entry is still exactly as it was. Otherwise why not
    /// (Roll Back is the way out).
    public func finishBlocker(for record: MoveRecord) -> String? {
        guard record.state == .started, record.isMove else { return "It isn't an unfinished move." }
        for item in record.items {
            if let want = item.dstSHA256 {
                let have = MoveFiles.sha256(of: URL(fileURLWithPath: item.dstPath))
                if have == nil { return "\"\(item.title)\" is gone from \(record.to.name)." }
                if have != want { return "\"\(item.title)\" changed in \(record.to.name) since the move started." }
            } else {
                let have = MoveFiles.sha256(of: URL(fileURLWithPath: item.srcPath))
                if have == nil { return "\"\(item.title)\" is gone from \(item.from.name)." }
                if have != item.srcSHA256 { return "\"\(item.title)\" changed in \(item.from.name) since the move started." }
            }
        }
        return nil
    }

    public func canFinish(_ record: MoveRecord) -> Bool { finishBlocker(for: record) == nil }

    /// Checks before a Finish: allowed copies, the session not busy, and the move still finishable.
    public func finishPlan(for record: MoveRecord, allowQuit: Bool = false) -> RestorePlan {
        var plan = restorePlan(for: record, allowQuit: allowQuit)
        plan.rows.removeAll { $0.kind == .family }
        if let why = finishBlocker(for: record) { plan.rows.append(CheckRow(.state, .block, "This move can't be finished.", detail: why)) }
        else { plan.rows.append(CheckRow(.state, .pass, "The move picks up where it stopped.", detail: stepText(record))) }
        plan.rows.removeAll { $0.kind == .destination && $0.title.contains("newer entry") }   // the source is the old copy here
        return plan
    }

    func stepText(_ record: MoveRecord) -> String? {
        record.step.map { "Reached: \(Self.stepTitle($0))." }
    }

    static func stepTitle(_ step: String) -> String {
        switch step {
        case "backup": "backed up"
        case "writeDestination": "session file written"
        case "group": "group moved"
        case "idx": "archive list updated"
        case "sideFiles": "side files moved"
        case "lease": "worktree lease transferred"
        case "verify": "verified"
        case "deleteSource": "removing the old file"
        default: step
        }
    }

    /// Completes the remaining steps of an interrupted move. Quits the copies it touches first, reopens them after
    /// (and those that were running when the move began). A failure leaves the journal unfinished: try again, or roll back.
    @discardableResult
    public func finish(_ record: MoveRecord, reopen: Bool = true, cancel: CancelToken? = nil,
                       progress: (@Sendable (MoveStep, MoveStepState) -> Void)? = nil) throws -> MoveOutcome {
        guard let current = self.record(id: record.id) else { throw MoveError.noRecord(record.id) }
        if let why = finishBlocker(for: current) { throw MoveError.cantFinish(why) }
        let pre = finishPlan(for: current, allowQuit: true).blocks
        return try orchestrate(
            copies: copies(of: current), reopen: reopen, cancel: cancel, alsoReopen: current.reopen ?? [], progress: progress,
            precheck: { pre }, settle: { self.finishPlan(for: current).blocks },
            body: {
                progress?(.moveFiles, .running)
                let r = try self.finishCore(current)
                progress?(.moveFiles, .done)
                return r
            })
    }

    /// Finish without touching any app: the copies must already be quit.
    @discardableResult
    func finishCore(_ rec: MoveRecord) throws -> MoveRecord {
        let plan = finishPlan(for: rec)
        if plan.isBlocked { throw MoveError.blocked(plan.blocks) }
        var works: [Work] = []
        var pending: [Bool] = []
        do {
            for item in rec.items { let r = try resume(item, in: rec); works.append(r.work); pending.append(r.needsWrite) }
        } catch { throw MoveError.cantFinish(error.localizedDescription) }
        let run = MoveRun(record: rec, jpath: journalURL(rec), engine: self)
        do {
            // A session that hadn't reached the destination yet is written now, exactly as the move would have.
            for (n, w) in works.enumerated() where pending[n] {
                run.record.createdDirs += try MoveFiles.makeDirs(w.dstFolder).map(\.path)
                try MoveFiles.writeAtomic(w.finalData, to: w.dstURL, mode: 0o600)
                try run.fail("writeDestination")
                run.record.items[n].dstSHA256 = MoveFiles.sha256(w.finalData)
                try run.mark("writeDestination")
            }
            for (n, w) in works.enumerated() { try applySideEffects(w, item: n, run: run) }
            for (n, w) in works.enumerated() where !w.sameCopy && !run.record.items[n].leases.isEmpty { try transferLeases(w) }
            try run.fail("lease")
            try run.mark("lease")
            try verifyDestinations(works)
            try run.fail("verify")
            try run.mark("verify")
            try removeSources(works, run: run)
            run.record.state = .done
            run.record.step = "done"
            run.record.finishedAt = Date()
            try run.write()
            return run.record
        } catch let e as MoveError {
            throw e
        } catch {
            throw MoveError.cantFinish(error.localizedDescription)
        }
    }

    /// A `Work` rebuilt from the journal and the disk, for the steps that remain. The destination entry must still
    /// match what was journaled; one that was never written is rebuilt from the untouched source.
    func resume(_ item: MoveRecord.Item, in rec: MoveRecord) throws -> (work: Work, needsWrite: Bool) {
        let dstURL = URL(fileURLWithPath: item.dstPath), srcURL = URL(fileURLWithPath: item.srcPath)
        let needsWrite = item.dstSHA256 == nil
        let data = try Data(contentsOf: needsWrite ? srcURL : dstURL)
        guard MoveFiles.sha256(data) == (item.dstSHA256 ?? item.srcSHA256),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoveFiles.Failure(message: "The entry for \"\(item.title)\" changed.")
        }
        var final = data
        if needsWrite {
            let (newEntry, _, changed) = Self.rewriteEntry(dict, sameOrg: item.fromOrgID == rec.toOrgID)
            if changed { final = try MoveFiles.encode(newEntry, pretty: false) }
        }
        let srcData = URL(fileURLWithPath: item.from.dataPath), dstData = URL(fileURLWithPath: rec.to.dataPath)
        let sameCopy = item.from.bundleID == rec.to.bundleID
        let srcFolder = srcURL.deletingLastPathComponent(), dstFolder = dstURL.deletingLastPathComponent()
        let cli = item.cliSessionId ?? String(item.sessionID.dropFirst("local_".count))
        let wiDir = srcFolder.appendingPathComponent("waiting-input")
        let wi = ((try? FileManager.default.contentsOfDirectory(atPath: wiDir.path)) ?? [])
            .filter { $0.hasPrefix(item.sessionID) || (!cli.isEmpty && $0.hasPrefix(cli)) }.sorted()
            .map { wiDir.appendingPathComponent($0) }
        let notes = srcData.appendingPathComponent("side-session-notes").appendingPathComponent(item.sessionID)
        var isDir: ObjCBool = false
        let hasNotes = !sameCopy && FileManager.default.fileExists(atPath: notes.path, isDirectory: &isDir) && isDir.boolValue
        let srcScope = "\(item.fromAccountID)/\(item.fromOrgID)"
        var w = Work(sid: item.sessionID, title: item.title, cliSessionId: item.cliSessionId, srcRef: item.from,
                     srcData: srcData, dstData: dstData, srcURL: srcURL, dstURL: dstURL, srcFolder: srcFolder, dstFolder: dstFolder,
                     srcAcct: item.fromAccountID, srcOrg: item.fromOrgID, dstAcct: rec.toAccountID, dstOrg: rec.toOrgID,
                     sameCopy: sameCopy, data: data, dict: dict, leaseNames: item.leases,
                     moveGroup: false, idxSrc: false, idxDst: false, isArchived: dict["isArchived"] as? Bool == true,
                     waitingInput: wi, notes: hasNotes ? notes : nil)
        w.moveGroup = groupAssignment(prefs: w.srcPrefs, scope: srcScope, sid: item.sessionID) != nil
        w.idxSrc = archiveIndexContains(srcFolder, item.sessionID) == true
        w.idxDst = archiveIndexContains(dstFolder, item.sessionID) == false
        w.finalData = final
        return (w, needsWrite)
    }

    func journalURL(_ rec: MoveRecord) -> URL {
        backupsDir.appendingPathComponent(rec.backupFolderName, isDirectory: true).appendingPathComponent("journal.json")
    }

    /// Puts an interrupted move back as it was, from its backup. Quits the copies first and reopens them after.
    @discardableResult
    public func rollBack(_ record: MoveRecord, reopen: Bool = true, cancel: CancelToken? = nil,
                         progress: (@Sendable (MoveStep, MoveStepState) -> Void)? = nil) throws -> MoveOutcome {
        guard let current = self.record(id: record.id) else { throw MoveError.noRecord(record.id) }
        guard current.state == .started else { throw MoveError.cantFinish("It isn't an unfinished move.") }
        return try undoWithQuit(current, reopen: reopen, cancel: cancel, progress: progress)
    }

    // MARK: Undo with quit

    /// Undo (or Restore, or Roll Back, or Archive Copy) that quits the copies it touches and reopens them after.
    @discardableResult
    public func undoWithQuit(_ record: MoveRecord, reopen: Bool = true, cancel: CancelToken? = nil,
                             progress: (@Sendable (MoveStep, MoveStepState) -> Void)? = nil) throws -> MoveOutcome {
        guard let current = self.record(id: record.id) else { throw MoveError.noRecord(record.id) }
        let pre = restorePlan(for: current, allowQuit: true).blocks
        let refs = current.isCopy ? [current.to] : copies(of: current)
        return try orchestrate(
            copies: refs, reopen: reopen, cancel: cancel, alsoReopen: current.state == .started ? (current.reopen ?? []) : [],
            progress: progress,
            precheck: { pre }, settle: { self.restorePlan(for: current).blocks },
            body: {
                progress?(.moveFiles, .running)
                let r = try self.undo(current)
                progress?(.moveFiles, .done)
                return r
            })
    }
}
