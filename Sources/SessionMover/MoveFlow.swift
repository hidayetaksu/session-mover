import SwiftUI
import AppKit
import Observation
import SessionMoverKit

// MARK: Models

struct ToastAction: Identifiable {
    let id = UUID()
    let title: String
    let run: @MainActor () -> Void
}

struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var actions: [ToastAction] = []
    var sticky = false
}

enum StepProgress { case pending, running, done }

/// One open Move, Restore, Finish or Open a Copy sheet.
@MainActor @Observable
final class MoveSession: Identifiable {
    enum Kind {
        case move(entries: [SessionEntry], destination: MoveDestination)
        /// Restore a finished move, roll back an unfinished one, or archive a copy.
        case restore(MoveRecord)
        /// Finish an interrupted move.
        case finish(MoveRecord)
        case copy(entry: SessionEntry, destination: MoveDestination)
    }
    enum Phase: Equatable { case review, running, finished, failed(message: String, log: String?) }

    let id = UUID()
    var kind: Kind
    var plan: MovePlan?
    var restorePlan: RestorePlan?
    var copyPlan: CopyPlan?
    var phase: Phase = .review
    /// Built to replace an entry already at the destination.
    var replace = false
    var confirmReplace = false
    var replaceConfirmed = false
    var steps: [MoveStep: StepProgress] = [:]
    var stepList: [MoveStep] = MoveStep.plain
    var stepStarted: [MoveStep: Date] = [:]
    var stepElapsed: [MoveStep: TimeInterval] = [:]
    /// "Claude and Alpha": the copies that quit and reopen.
    var appNames = ""
    /// The copy that didn't quit, for "Show <Name>".
    var failedApp: InstanceRef?
    var cancel = CancelToken()
    var showFiles = false
    var showLog = false

    init(kind: Kind) { self.kind = kind }

    var isMove: Bool { if case .move = kind { true } else { false } }
    var isRestore: Bool { if case .restore = kind { true } else { false } }
    var isFinish: Bool { if case .finish = kind { true } else { false } }
    var isCopy: Bool { if case .copy = kind { true } else { false } }
    var record: MoveRecord? {
        switch kind { case .restore(let r), .finish(let r): r; default: nil }
    }
    var isCopyUndo: Bool { record?.isCopy == true }

    func begin(steps list: [MoveStep]) {
        stepList = list
        steps = Dictionary(uniqueKeysWithValues: list.map { ($0, StepProgress.pending) })
        stepStarted = [:]; stepElapsed = [:]
        cancel = CancelToken()
    }

    func progress(_ step: MoveStep, _ state: MoveStepState) {
        guard steps[step] != nil else { return }
        switch state {
        case .running: steps[step] = .running; stepStarted[step] = Date()
        case .done:
            steps[step] = .done
            if let t = stepStarted[step] { stepElapsed[step] = Date().timeIntervalSince(t) }
        }
    }

    /// Stop (⌘.) works while Quit or Back up is the step in flight. From step 3 a move is never left half-done.
    var canStop: Bool {
        guard phase == .running, isMove else { return false }
        return !steps.contains { $0.key.canStop == false && $0.value != .pending }
    }
}

// MARK: Starting a move

extension AppStore {
    /// Entries for the current selection (or the given row ids).
    func entries(forRowIDs ids: [String]) -> [SessionEntry] {
        let set = Set(ids)
        return library.allEntries.filter { set.contains($0.rowID) }
    }

    /// Opens the Move sheet. Nothing moves until the user presses the default button.
    func beginMove(_ entries: [SessionEntry], to destination: MoveDestination) {
        guard !entries.isEmpty, !isMoving else { return }
        engine.labels = settings.labels
        let session = MoveSession(kind: .move(entries: entries, destination: destination))
        session.plan = engine.preflight(sessions: entries, to: destination, allowQuit: true)
        moveSession = session
    }

    /// The organization picker on the sheet: run the checks again with that organization.
    func chooseOrg(_ session: MoveSession, orgID: String) {
        guard case .move(let entries, let dest) = session.kind, session.phase == .review else { return }
        var d = dest
        d.accountID = dest.accountID ?? session.plan?.items.compactMap(\.dstAccountID).first
        d.orgID = orgID
        engine.labels = settings.labels
        session.kind = .move(entries: entries, destination: d)
        session.plan = engine.preflight(sessions: entries, to: d, allowQuit: true, replace: session.replace)
    }

    /// Replace: the same sheet, with the entry already at the destination replaced (after a backup).
    func beginReplace(_ session: MoveSession) {
        guard case .move(let entries, let dest) = session.kind else { return }
        let replacing = engine.preflight(sessions: entries, to: dest, allowQuit: true, replace: true)
        guard replacing.canMove else {
            alertMessage = "Replace isn't possible here. \(replacing.items.flatMap(\.blocks).first?.title ?? "")"
            return
        }
        session.replace = true
        session.plan = replacing
    }

    /// Try Again: run the checks again and go back to the review.
    func retry(_ session: MoveSession) {
        switch session.kind {
        case .move(let entries, let dest): session.plan = engine.preflight(sessions: entries, to: dest, allowQuit: true, replace: session.replace)
        case .restore(let rec): session.restorePlan = engine.restorePlan(for: rec, allowQuit: true)
        case .finish(let rec): session.restorePlan = engine.finishPlan(for: rec, allowQuit: true)
        case .copy(let e, let dest): session.copyPlan = engine.copyPlan(entry: e, to: dest)
        }
        session.phase = .review
        session.showLog = false
        session.failedApp = nil
    }

    /// "Open a Copy Instead": a busy app can't quit, but the deep link works while apps run.
    func openCopyInstead(_ session: MoveSession) {
        guard case .move(let entries, let dest) = session.kind, entries.count == 1 else { return }
        moveSession = nil
        DispatchQueue.main.async { self.beginCopy(entries[0], to: dest) }
    }

    func beginCopy(_ entry: SessionEntry, to destination: MoveDestination) {
        guard !isMoving else { return }
        engine.labels = settings.labels
        let s = MoveSession(kind: .copy(entry: entry, destination: destination))
        s.copyPlan = engine.copyPlan(entry: entry, to: destination)
        moveSession = s
    }

    /// One destination per copy: the account it is signed in to.
    func beginCopySelection(to destination: MoveDestination) {
        if let e = selectedEntries.first, selectedEntries.count == 1 { beginCopy(e, to: destination) }
    }

    func beginMoveSelection(to destination: MoveDestination) { beginMove(selectedEntries, to: destination) }

    /// Accounts a copy offers as destinations: its folders' accounts plus the one it is signed in to.
    func destinationAccounts(_ scan: InstanceScan) -> [String] {
        var a = scan.accountIDs
        if let s = scan.signedInAccountID, !a.contains(s) { a.insert(s, at: 0) }
        return a
    }

    /// True when every entry already sits in that account of that copy.
    func isCurrent(_ entries: [SessionEntry], instance: String, account: String) -> Bool {
        !entries.isEmpty && entries.allSatisfy { $0.instanceID == instance && $0.accountID == account }
    }

    /// Organizations of an account that hold sessions. Only when there is more than one does a menu offer the level.
    func destinationOrgs(_ scan: InstanceScan, _ account: String) -> [OrgChoice] {
        let full = scan.orgs.filter { $0.accountID == account && !$0.entries.isEmpty }
        guard full.count > 1 else { return [] }
        return full.map { OrgChoice(orgID: $0.orgID, label: orgName($0.orgID), entryCount: $0.entries.count) }
    }

    func destinationLabel(_ scan: InstanceScan, _ account: String) -> String {
        "\(scan.instance.name) ▸ \(accountName(account))"
    }

    // MARK: Running a move

    func confirm(_ session: MoveSession) {
        guard session.phase == .review else { return }
        switch session.kind {
        case .move:
            if session.replace && !session.replaceConfirmed { session.confirmReplace = true; return }
            runMove(session)
        case .restore(let rec): runRestore(session, rec)
        case .finish(let rec): runFinish(session, rec)
        case .copy: runCopy(session)
        }
    }

    private func names(_ list: [Instance]) -> String {
        let n = list.map(\.name)
        return n.count <= 2 ? n.joined(separator: " and ") : n.dropLast().joined(separator: ", ") + " and " + n.last!
    }

    private func runMove(_ session: MoveSession) {
        guard let plan = session.plan, plan.canMove, !isMoving else { return }
        isMoving = true
        session.phase = .running
        let quitting = !plan.mustQuit.isEmpty
        session.appNames = names(plan.mustQuit)
        session.begin(steps: quitting ? MoveStep.orchestrated : MoveStep.plain)
        let engine = engine
        let skipped = plan.blocked
        let phrase = plan.destinationPhrase
        let dest = plan.destination
        let token = session.cancel
        Task {
            let result: Result<MoveOutcome, Error> = await Task.detached(priority: .userInitiated) {
                let report: @Sendable (MoveStep, MoveStepState) -> Void = { step, state in
                    Task { @MainActor in session.progress(step, state) }
                }
                do {
                    if quitting { return .success(try engine.performWithQuit(plan, cancel: token, progress: report)) }
                    return .success(MoveOutcome(record: try engine.perform(plan, progress: report, cancelled: { token.isCancelled })))
                } catch { return .failure(error) }
            }.value
            isMoving = false
            history = engine.history()
            rescan()
            switch result {
            case .success(let outcome):
                let rec = outcome.record
                session.phase = .finished
                lastUndo = rec
                let n = rec.items.count
                var text = n == 1 ? "Moved \"\(rec.items[0].title)\" to \(phrase)." : "Moved \(n) sessions to \(phrase)."
                if !skipped.isEmpty { text = "Moved \(n) session\(n == 1 ? "" : "s"). \(skipped.count) skipped: \(Self.shortReason(skipped[0]))." }
                var actions = [
                    ToastAction(title: "Undo") { [weak self] in self?.undo(rec) },
                    ToastAction(title: "Show") { [weak self] in self?.show(rec, destination: dest) }]
                if !outcome.reopenFailed.isEmpty {
                    text += " Couldn't reopen \(Self.joinNames(outcome.reopenFailed.map(\.name))). The move is done."
                    for r in outcome.reopenFailed {
                        actions.append(ToastAction(title: "Open \(r.name)") { [weak self] in self?.openApp(at: r) })
                    }
                }
                showToast(Toast(text: text, actions: actions, sticky: !outcome.reopenFailed.isEmpty))
                try? await Task.sleep(for: .milliseconds(600))
                if moveSession?.id == session.id { moveSession = nil }
            case .failure(let error):
                fail(session, error)
            }
            if quitAfterMove { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    /// Failure outcomes of spec section 5: what the sheet says, and which buttons it offers.
    private func fail(_ session: MoveSession, _ error: Error) {
        let me = error as? MoveError
        var message = error.localizedDescription
        switch me {
        case .cancelled?:
            session.phase = .review
            showToast(Toast(text: "Stopped. Nothing changed."))
            return
        case .didntQuit(let name)?:
            message = "\(name) didn't quit. It may be showing a dialog."
            if let plan = session.plan, let i = plan.mustQuit.first(where: { $0.name == name }) { session.failedApp = InstanceRef(i) }
            else if let r = session.restorePlan?.record { session.failedApp = ([r.to] + r.items.map(\.from)).first { $0.name == name } }
        case .rollbackFailed?: message += " Open History to restore from the backup."
        case .simulatedCrash?: break
        default: break
        }
        session.phase = .failed(message: message, log: me?.log)
        if case .rolledBack = me { showToast(Toast(text: "Move rolled back. Nothing changed.", actions: [ToastAction(title: "Show Log") { session.showLog = true }])) }
    }

    static func joinNames(_ n: [String]) -> String {
        n.count <= 2 ? n.joined(separator: " and ") : n.dropLast().joined(separator: ", ") + " and " + n.last!
    }

    /// "Show <Name>": brings a copy that won't quit to the front, so its dialog can be answered.
    func showApp(_ ref: InstanceRef) {
        NSRunningApplication.runningApplications(withBundleIdentifier: ref.bundleID).first { !$0.isTerminated }?.activate()
    }

    /// "Open <Name>": reopens a copy by its own app bundle (never the `.real` binary).
    func openApp(at ref: InstanceRef) {
        let url = URL(fileURLWithPath: ref.appPath)
        guard url.pathExtension == "app" else { return }
        Task { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }

    static func shortReason(_ s: SessionPlan) -> String {
        guard let b = s.blocks.first else { return "blocked" }
        switch b.kind {
        case .state: return b.title.contains("busy") ? "busy" : "open in a terminal"
        case .destination: return s.isDuplicate ? "already there" : "can't move there"
        case .apps: return "app is open"
        case .version: return "version not verified"
        case .allowlist: return "moves turned off"
        case .lease: return "worktree in use"
        default: return b.kind.rawValue
        }
    }

    // MARK: Toast

    func showToast(_ t: Toast) {
        toast = t
        toastTask?.cancel()
        guard !t.sticky else { return }
        let id = t.id
        toastTask = Task {
            try? await Task.sleep(for: .seconds(t.actions.isEmpty ? 4 : 9))
            if !Task.isCancelled, toast?.id == id { toast = nil }
        }
    }

    /// Quit. An attached sheet makes AppKit refuse `terminate:` ("User canceled"), so take the sheets down first.
    func quit() {
        showFirstRun = false
        showMovePicker = false
        showCopyPicker = false
        if !isMoving { launchRecovery = false; moveSession = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    func dismissToast() { toast = nil; toastTask?.cancel() }

    /// Scope to the destination account and select what moved.
    func show(_ rec: MoveRecord, destination: MoveDestination) {
        guard let inst = library.instances.first(where: { $0.instance.bundleID == rec.to.bundleID }) else { return }
        scope = .account(instance: inst.id, account: rec.toAccountID)
        filter = .all
        selection = rec.isCopy ? [] : Set(rec.items.map(\.dstPath))
        dismissToast()
    }

    // MARK: Undo and Restore

    var undoTitle: String? {
        guard let r = lastUndo else { return nil }
        let t = r.title
        let clipped = t.count > 28 ? String(t.prefix(27)) + "…" : t
        return r.isCopy ? "Open Copy \"\(clipped)\"" : "Move \"\(clipped)\""
    }

    /// ⌘Z and the toast's Undo. Runs in a toast when every check passes (apps quitting and reopening is expected);
    /// opens the sheet when something needs a look. Undo for a copy archives it.
    func undo(_ rec: MoveRecord) {
        guard !isMoving else { return }
        engine.labels = settings.labels
        let plan = engine.restorePlan(for: rec, allowQuit: true)
        if plan.isBlocked || plan.rows.contains(where: { $0.status == .warn && $0.kind != .apps }) { beginRestore(rec); return }
        isMoving = true
        let what = rec.sessionCount == 1 ? "\"\(Self.clip(rec.title))\"" : "\(rec.sessionCount) sessions"
        showToast(Toast(text: rec.isCopy ? "Archiving the copy of \(what)" : "Restoring \(what)", sticky: true))
        let engine = engine
        Task {
            let r: Result<MoveOutcome, Error> = await Task.detached { do { return .success(try engine.undoWithQuit(rec)) } catch { return .failure(error) } }.value
            finishRestore(r, rec)
        }
    }

    func undoLast() { if let r = lastUndo { undo(r) } }

    func beginRestore(_ rec: MoveRecord) {
        guard !isMoving else { return }
        engine.labels = settings.labels
        let s = MoveSession(kind: .restore(rec))
        s.restorePlan = engine.restorePlan(for: rec, allowQuit: true)
        moveSession = s
    }

    /// Finish an interrupted move (History row, or the sheet at launch).
    func beginFinish(_ rec: MoveRecord) {
        guard !isMoving else { return }
        engine.labels = settings.labels
        let s = MoveSession(kind: .finish(rec))
        s.restorePlan = engine.finishPlan(for: rec, allowQuit: true)
        moveSession = s
    }

    private func runRestore(_ session: MoveSession, _ rec: MoveRecord) {
        guard let plan = session.restorePlan, !plan.isBlocked, !isMoving else { return }
        runRecordOperation(session, rec, plan: plan) { engine, token, report in
            try engine.undoWithQuit(rec, cancel: token, progress: report)
        }
    }

    private func runFinish(_ session: MoveSession, _ rec: MoveRecord) {
        guard let plan = session.restorePlan, !plan.isBlocked, !isMoving else { return }
        runRecordOperation(session, rec, plan: plan) { engine, token, report in
            try engine.finish(rec, cancel: token, progress: report)
        }
    }

    /// Restore, Roll Back, Archive Copy and Finish share one progress list: quit, the work, reopen.
    private func runRecordOperation(_ session: MoveSession, _ rec: MoveRecord, plan: RestorePlan,
                                    _ work: @escaping @Sendable (MoveEngine, CancelToken, @escaping @Sendable (MoveStep, MoveStepState) -> Void) throws -> MoveOutcome) {
        isMoving = true
        session.phase = .running
        let quitting = plan.rows.contains { $0.kind == .apps && $0.status == .warn }
        session.appNames = Self.appNamesIn(plan)
        session.begin(steps: quitting ? [.quit, .moveFiles, .reopen] : [.moveFiles])
        let engine = engine
        let token = session.cancel
        Task {
            let r: Result<MoveOutcome, Error> = await Task.detached(priority: .userInitiated) {
                let report: @Sendable (MoveStep, MoveStepState) -> Void = { step, state in Task { @MainActor in session.progress(step, state) } }
                do { return .success(try work(engine, token, report)) } catch { return .failure(error) }
            }.value
            if case .success = r { session.phase = .finished; try? await Task.sleep(for: .milliseconds(600)); if moveSession?.id == session.id { moveSession = nil } }
            else if case .failure(let e) = r { fail(session, e) }
            finishRestore(r, rec, quiet: true)
        }
    }

    /// The names in "A and B are open. They quit, then reopen…".
    private static func appNamesIn(_ plan: RestorePlan) -> String {
        guard let t = plan.rows.first(where: { $0.kind == .apps && $0.status == .warn })?.title else { return "" }
        for sep in [" are open.", " is open."] { if let r = t.range(of: sep) { return String(t[..<r.lowerBound]) } }
        return ""
    }

    private func finishRestore(_ r: Result<MoveOutcome, Error>, _ rec: MoveRecord, quiet: Bool = false) {
        isMoving = false
        history = engine.history()
        rescan()
        switch r {
        case .success(let outcome):
            let done = outcome.record
            if lastUndo?.id == done.id { lastUndo = nil }
            if rec.isCopy {
                settings.removeCopyMarks(moveID: rec.id)
                saveSettings()
            }
            let first = done.items[0]
            var text: String
            if rec.isCopy { text = "Archived the copy in \(rec.to.name). It isn't deleted." }
            else if rec.state == .started { text = done.state == .done ? "Finished the move." : "Rolled back. Everything is as it was." }
            else {
                text = done.items.count == 1
                    ? "Restored to \(engine.phrase(first.from.name, account: first.fromAccountID))."
                    : "Restored \(done.items.count) sessions."
            }
            if rec.state == .started && done.state == .done { text = "Finished the move." }
            var actions: [ToastAction] = []
            if !outcome.reopenFailed.isEmpty {
                text += " Couldn't reopen \(Self.joinNames(outcome.reopenFailed.map(\.name))). The work is done."
                for ref in outcome.reopenFailed { actions.append(ToastAction(title: "Open \(ref.name)") { [weak self] in self?.openApp(at: ref) }) }
            }
            showToast(Toast(text: text, actions: actions, sticky: !actions.isEmpty))
        case .failure(let e):
            if let me = e as? MoveError, case .cancelled = me { dismissToast() }
            else if !quiet { showToast(Toast(text: e.localizedDescription, sticky: false)) }
            else { dismissToast() }
        }
        if quitAfterMove { NSApp.reply(toApplicationShouldTerminate: true) }
        if launchRecovery { presentNextRecovery() }
    }

    // MARK: Interrupted moves

    /// At launch, before anything else: the first unfinished move gets "Finish an interrupted move?".
    func presentNextRecovery() {
        guard !isMoving else { return }
        if let rec = engine.recoverableMoves().first(where: { rec in !recoverySkipped.contains(rec.id) }) {
            launchRecovery = true
            DispatchQueue.main.async {
                if self.moveSession == nil { self.engine.canFinish(rec) ? self.beginFinish(rec) : self.beginRestore(rec) }
            }
        } else {
            launchRecovery = false
            if pendingFirstRun { pendingFirstRun = false; showFirstRun = true }
        }
    }

    /// The sheet was closed without choosing (a blocked move). Don't ask again until the next launch.
    func skipRecovery(_ rec: MoveRecord) {
        recoverySkipped.insert(rec.id)
        moveSession = nil
        presentNextRecovery()
    }

    // MARK: Open a copy

    private func runCopy(_ session: MoveSession) {
        guard let plan = session.copyPlan, plan.canCopy, !isMoving else { return }
        isMoving = true
        session.phase = .running
        session.begin(steps: [.moveFiles])
        session.progress(.moveFiles, .running)
        let engine = engine
        let phrase = plan.destinationPhrase
        Task {
            do {
                let rec = try await engine.performCopy(plan)
                session.progress(.moveFiles, .done)
                isMoving = false
                if let mark = engine.copyMark(for: rec) { settings.addCopyMark(mark); saveSettings() }
                history = engine.history()
                lastUndo = rec
                rescan()
                session.phase = .finished
                showToast(Toast(text: "Opened a copy in \(phrase).", actions: [
                    ToastAction(title: "Show") { [weak self] in self?.show(rec, destination: MoveDestination(instanceID: rec.to.bundleID)) }]))
                try? await Task.sleep(for: .milliseconds(600))
                if moveSession?.id == session.id { moveSession = nil }
            } catch {
                isMoving = false
                session.phase = .failed(message: error.localizedDescription, log: (error as? MoveError)?.log)
            }
            if quitAfterMove { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    // MARK: History

    func reloadHistory() { history = engine.history() }

    var historySummary: String {
        let bytes = history.reduce(Int64(0)) { $0 + $1.backupBytes }
        return "\(history.count) move\(history.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of backups"
    }
    var unfinishedMoves: Int { history.filter { $0.record.state == .started }.count }

    func emptyHistory() {
        do { try engine.emptyHistory(); lastUndo = nil }
        catch { alertMessage = "Couldn't empty History: \(error.localizedDescription)" }
        reloadHistory()
    }

    static func clip(_ s: String, _ n: Int = 28) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    // MARK: Drag and drop (section 4)

    func startDrag(_ e: SessionEntry) {
        if !selection.contains(e.rowID) { selection = [e.rowID] }
        dragRowIDs = Array(selection)
        dragPlans = [:]
        dragCopyPlans = [:]
        dropTarget = nil
        dropBadge = nil
    }

    func destination(for target: Scope) -> MoveDestination? {
        switch target {
        case .instance(let i): MoveDestination(instanceID: i)
        case .account(let i, let a): MoveDestination(instanceID: i, accountID: a)
        case .org(let i, let a, let o): MoveDestination(instanceID: i, accountID: a, orgID: o)
        default: nil
        }
    }

    /// The preflight for the dragged sessions against one target, cached for the duration of the drag.
    func dragPlan(for target: Scope) -> MovePlan? {
        if let p = dragPlans[target] { return p }
        guard let dest = destination(for: target), !dragRowIDs.isEmpty else { return nil }
        engine.labels = settings.labels
        let p = engine.preflight(sessions: entries(forRowIDs: dragRowIDs), to: dest, library: library, allowQuit: true)
        dragPlans[target] = p
        return p
    }

    /// The same for Option-drag: Open a copy works on one session.
    func dragCopyPlan(for target: Scope) -> CopyPlan? {
        if let p = dragCopyPlans[target] { return p }
        guard let dest = destination(for: target), dragRowIDs.count == 1, let e = entries(forRowIDs: dragRowIDs).first else { return nil }
        engine.labels = settings.labels
        let p = engine.copyPlan(entry: e, to: dest, library: library)
        dragCopyPlans[target] = p
        return p
    }

    /// Badge text for the target, or nil when it's valid. Order follows section 4.
    func dropRefusal(_ target: Scope) -> String? {
        if optionDown {
            if dragRowIDs.count != 1 { return "Open a copy works on one session at a time." }
            guard let plan = dragCopyPlan(for: target) else { return "Can't drop here." }
            return plan.canCopy ? nil : (plan.blocks.first?.title ?? "Can't open a copy here.")
        }
        guard let plan = dragPlan(for: target) else { return "Can't drop here." }
        if plan.canMove { return nil }
        let blocks = plan.items.flatMap(\.blocks)
        func first(_ test: (CheckRow) -> Bool) -> CheckRow? { blocks.first(where: test) }
        if let b = first({ $0.kind == .state && $0.title.contains("busy") }) { return "Can't move: \(b.title.trimmingCharacters(in: CharacterSet(charactersIn: ".")))" }
        if first({ $0.kind == .state }) != nil { return "Can't move: open in Terminal" }
        if let b = first({ $0.kind == .destination }) { return b.title }
        if first({ $0.kind == .version }) != nil { return "Only Open a copy works here. Hold Option." }
        if let b = first({ $0.kind == .allowlist }) { return b.title }
        if let b = first({ $0.kind == .apps }) { return b.title }
        return blocks.first?.title ?? "Can't move here."
    }

    func dropBadgeText(_ target: Scope) -> String {
        if let r = dropRefusal(target) { return r }
        if optionDown { return "Open a copy in \(dragCopyPlan(for: target)?.destinationPhrase ?? "")" }
        guard let plan = dragPlan(for: target) else { return "" }
        var text = "Move to \(plan.destinationPhrase)"
        if plan.items.count > 1, plan.movable.count < plan.items.count {
            text = "Move \(plan.movable.count) of \(plan.items.count) to \(plan.destinationPhrase)"
        }
        if !plan.mustQuit.isEmpty { text += "\n\(names(plan.mustQuit)) will quit and reopen" }
        return text
    }

    /// Option can be pressed or released mid-drag: the badge and highlight follow it.
    func updateModifier(for target: Scope) {
        let now = NSEvent.modifierFlags.contains(.option)
        guard now != optionDown else { return }
        optionDown = now
        if dropTarget == target { dropBadge = dropBadgeText(target) }
    }

    func dropEntered(_ target: Scope) {
        guard !dragRowIDs.isEmpty else { return }
        optionDown = NSEvent.modifierFlags.contains(.option)
        dropTarget = target
        dropBadge = dropBadgeText(target)
        // Spring-loading: a collapsed instance opens after the hover delay.
        springTask?.cancel()
        springBlink = nil
        if case .instance(let i) = target, !expandedInstances.contains(i) {
            springTask = Task {
                // The row blinks twice, then opens (no blink with Reduce Motion).
                if AppStore.reduceMotion {
                    try? await Task.sleep(for: .milliseconds(700))
                } else {
                    try? await Task.sleep(for: .milliseconds(380))
                    for _ in 0..<2 {
                        if Task.isCancelled || dropTarget != target { break }
                        springBlink = i
                        try? await Task.sleep(for: .milliseconds(80))
                        springBlink = nil
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                }
                springBlink = nil
                if !Task.isCancelled, dropTarget == target, !expandedInstances.contains(i) { expandedInstances.insert(i); springOpened.insert(i) }
            }
        }
    }

    func dropExited(_ target: Scope) {
        if dropTarget == target { dropTarget = nil; dropBadge = nil }
        springTask?.cancel()
        springBlink = nil
    }

    func dropOperation(_ target: Scope) -> DropOperation { dropRefusal(target) == nil ? (optionDown ? .copy : .move) : .forbidden }

    /// A drop opens the sheet. It never moves files by itself.
    func performDrop(_ target: Scope) -> Bool {
        defer {
            dropTarget = nil; dropBadge = nil; springTask?.cancel(); springBlink = nil
            // Instances that sprang open close again after a drop elsewhere.
            if case .instance = target {} else { for i in springOpened { expandedInstances.remove(i) } }
            springOpened = []
        }
        optionDown = NSEvent.modifierFlags.contains(.option)
        guard dropRefusal(target) == nil, let dest = destination(for: target) else { return false }
        let entries = entries(forRowIDs: dragRowIDs)
        if optionDown, let e = entries.first { beginCopy(e, to: dest) } else { beginMove(entries, to: dest) }
        return true
    }
}
