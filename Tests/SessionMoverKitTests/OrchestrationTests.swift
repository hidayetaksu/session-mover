import XCTest
@testable import SessionMoverKit

/// A fake world of running Claude copies: it answers "is it running?" and quits and reopens copies on request.
final class FakeWorld: RunningAppsProviding, RealProcessChecking, AppControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _running: Set<String>
    private var _quits: [String] = []
    private var _reopens: [String] = []
    var failQuit: Set<String> = []
    var failReopen: Set<String> = []
    /// Bundle ids whose `.real` process survives a quit.
    var stuckReal: Set<String> = []
    var onQuit: (@Sendable (String) -> Void)?

    init(running: Set<String> = []) { _running = running }

    func lockedSet(_ ids: Set<String>) { lock.lock(); _running = ids; lock.unlock() }
    var running: Set<String> { lock.lock(); defer { lock.unlock() }; return _running }
    var quits: [String] { lock.lock(); defer { lock.unlock() }; return _quits }
    var reopens: [String] { lock.lock(); defer { lock.unlock() }; return _reopens }

    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func hasRealProcess(appURL: URL) -> Bool {
        // "Claude-alpha.app" -> com.anthropic.claudefordesktop-alpha; "Claude.app" -> com.anthropic.claudefordesktop
        let name = appURL.deletingPathExtension().lastPathComponent
        let id = name == "Claude" ? "com.anthropic.claudefordesktop" : "com.anthropic.claudefordesktop-" + name.dropFirst("Claude-".count)
        return stuckReal.contains(id)
    }
    func isRunning(_ copy: InstanceRef) -> Bool { isRunning(bundleID: copy.bundleID) }

    func quit(_ copy: InstanceRef, cancelled: @Sendable () -> Bool) throws {
        lock.lock(); _quits.append(copy.bundleID); lock.unlock()
        onQuit?(copy.bundleID)
        if cancelled() { throw AppControlError.cancelled }
        if failQuit.contains(copy.bundleID) { throw AppControlError.didntQuit(copy.name) }
        lock.lock(); _running.remove(copy.bundleID); lock.unlock()
    }
    func reopen(_ copy: InstanceRef) throws {
        lock.lock(); _reopens.append(copy.bundleID); lock.unlock()
        if failReopen.contains(copy.bundleID) { throw AppControlError.cantReopen(copy.name) }
        lock.lock(); _running.insert(copy.bundleID); lock.unlock()
    }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class OrchestrationTests: XCTestCase {
    var fx: Fixture!
    let orig = "Library/Application Support/Claude"
    let alpha = ".claude-profiles/alpha/Library/Application Support/Claude"
    let origID = "com.anthropic.claudefordesktop"
    let alphaID = "com.anthropic.claudefordesktop-alpha"
    var ctx: String { "claude-code-sessions/\(Fixture.acctA)/\(Fixture.orgX)" }
    var toAlphaA: MoveDestination { MoveDestination(instanceID: alphaID, accountID: Fixture.acctA) }

    override func setUpWithError() throws { fx = try makeFixture() }
    override func tearDown() { fx.cleanup() }

    func makeFixture() throws -> Fixture {
        let fx = try Fixture()
        let dir = fx.existingFolder
        try fx.write(#"{"sessionId":"local_aaaa0001","cliSessionId":"\#(Fixture.cliBusy)","cwd":"\#(dir)","originCwd":"\#(dir)","createdAt":1,"lastActivityAt":2,"title":"Fix export regex","cliBinaryPin":{"version":"2.1.309"},"remoteMcpServersConfig":[{"uuid":"u1","name":"Docs"}],"unknownField":{"a":[1,2],"b":null},"worktreeName":"wt-one","worktreePath":"\#(dir)/wt","branch":"claude/x","brandNew":"keep me"}"#,
                     "\(orig)/\(ctx)/local_aaaa0001.json")
        try fx.write(#"{"schemaVersion":2,"worktrees":{"wt-one":{"leasedBy":"local_aaaa0001","branch":"claude/x","adopted":true},"wt-other":{"leasedBy":"local_zzzz"}},"futureKey":"stay"}"#,
                     "\(orig)/git-worktrees.json")
        try fx.write(#"{"preferences":{"epitaxyPrefs":{"dframe-group-scopes":{"\#(Fixture.acctA)/\#(Fixture.orgX)":{"groups":[{"id":"cg-1","name":"Group One","mode":"code"}],"assignments":{"code:local_aaaa0001":"cg-1","code:local_other":"cg-1"},"order":{"cg-1":["code:local_aaaa0001","code:local_other"]}}}},"keepMe":1}}"#,
                     "\(orig)/\(MoveEngine.prefsFile)")
        try fx.write("{\"s\":1}", "\(orig)/\(ctx)/waiting-input/local_aaaa0001.json")
        try fx.write("note", "\(orig)/side-session-notes/local_aaaa0001/notes.md")
        try fx.write(#"{"v":1,"archived":["local_aaaa0002"]}"#, "\(orig)/\(ctx)/archived-sessions.idx")
        try fx.write(#"{"v":1,"archived":[]}"#, "\(alpha)/\(ctx)/archived-sessions.idx")
        // The fixture's busy process (pid of this test) belongs to aaaa0001; these tests start with nothing running.
        try? FileManager.default.removeItem(at: fx.home.appendingPathComponent(".claude/sessions/\(getpid()).json"))
        return fx
    }

    func engine(_ world: FakeWorld, fx useFx: Fixture? = nil, policy: WritePolicy = .all,
                alive: @escaping @Sendable (Int32) -> Bool = { _ in false }) -> MoveEngine {
        let e = MoveEngine(env: (useFx ?? fx).env, running: world, realProcesses: world, policy: policy,
                           formatGuard: FormatGuard(verified: ["4.29.0", "4.30.1"]), labels: AccountLabels(),
                           appController: world, isPIDAlive: alive)
        e.settleTimeout = 0
        return e
    }

    func entries(_ e: MoveEngine, _ ids: String...) -> [SessionEntry] {
        let lib = e.scanner.scan()
        return ids.map { id in lib.allEntries.first { $0.id == id }! }
    }
    func url(_ rel: String) -> URL { fx.home.appendingPathComponent(rel) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url(rel).path) }

    /// Every file and folder with a hash of its content (the fixture's own path made neutral) and mode,
    /// so moves in two different fixtures compare equal.
    func snapshot(_ f: Fixture? = nil) -> [String: String] {
        let f = f ?? fx!
        var out: [String: String] = [:]
        let home = f.home.resolvingSymlinksInPath()
        let skip = home.appendingPathComponent("Library/Application Support/SessionMover").path
        let roots = [f.root.path, f.root.resolvingSymlinksInPath().path]
        let en = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey])!
        while let raw = en.nextObject() as? URL {
            let u = raw.resolvingSymlinksInPath()
            if u.path.hasPrefix(skip) { continue }
            let rel = String(u.path.dropFirst(home.path.count))
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { out[rel] = "dir"; continue }
            var text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            for r in roots { text = text.replacingOccurrences(of: r, with: "ROOT") }
            let mode = MoveFiles.mode(of: u).map { String($0, radix: 8) } ?? "?"
            out[rel] = "\(MoveFiles.sha256(Data(text.utf8))) \(mode)"
        }
        return out
    }
    func diff(_ a: [String: String], _ b: [String: String]) -> [String] {
        Set(a.keys).union(b.keys).sorted().filter { a[$0] != b[$0] }.map { String($0.suffix(70)) }
    }

    // MARK: Preflight

    func testRunningCopiesWarnWhenQuitIsAllowed() throws {
        let world = FakeWorld(running: [origID, alphaID])
        let e = engine(world)
        let src = entries(e, "local_aaaa0001")
        let blocked = e.preflight(sessions: src, to: toAlphaA)
        XCTAssertFalse(blocked.canMove, "without --quit a running copy still blocks")
        XCTAssertEqual(blocked.buttonTitle, "Move")

        let plan = e.preflight(sessions: src, to: toAlphaA, allowQuit: true)
        XCTAssertTrue(plan.canMove, "\(plan.items[0].blocks)")
        let row = plan.items[0].rows.first { $0.kind == .apps }
        XCTAssertEqual(row?.status, .warn)
        XCTAssertEqual(row?.title, "Claude and Alpha are open. They quit, then reopen after the move.")
        XCTAssertEqual(plan.buttonTitle, "Quit & Move")
        XCTAssertEqual(Set(plan.mustQuit.map(\.name)), ["Claude", "Alpha"])

        let one = engine(FakeWorld(running: [alphaID])).preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        XCTAssertEqual(one.items[0].rows.first { $0.kind == .apps }?.title, "Alpha is open. It quits, then reopens after the move.")
        let none = engine(FakeWorld()).preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        XCTAssertEqual(none.buttonTitle, "Move")
        XCTAssertTrue(none.mustQuit.isEmpty)
    }

    func testBusySessionInAQuittingCopyBlocks() throws {
        let me = getpid()
        try fx.write(#"{"pid":\#(me),"sessionId":"\#(Fixture.cliBusy)","hostSessionId":"local_aaaa0001","status":"busy"}"#, ".claude/sessions/busy.json")
        let e = engine(FakeWorld(running: [origID]), alive: { $0 == me })
        let plan = e.preflight(sessions: entries(e, "local_aaaa0003"), to: toAlphaA, allowQuit: true)
        XCTAssertFalse(plan.canMove)
        XCTAssertEqual(plan.items[0].blocks.first { $0.kind == .apps }?.title,
                       "Claude has a busy session: \"Fix export regex\". It can't quit now.")
        XCTAssertTrue(plan.blockedByBusyApp)
        XCTAssertThrowsError(try e.performWithQuit(plan))
    }

    func testIdleSessionsInQuittingCopiesWarn() throws {
        let me = getpid()
        try fx.write(#"{"pid":\#(me),"sessionId":"fe56159c-da13-4589-aa09-bbfd51cb6d4e","hostSessionId":"local_aaaa0002","status":"idle"}"#, ".claude/sessions/idle.json")
        // the fixture also has an idle local_bbbb0002 in Alpha
        let both = engine(FakeWorld(running: [origID, alphaID]), alive: { $0 == me })
        let plan = both.preflight(sessions: entries(both, "local_aaaa0003"), to: toAlphaA, allowQuit: true)
        XCTAssertTrue(plan.canMove, "\(plan.items[0].blocks)")
        let row = plan.items[0].rows.first { $0.kind == .others }
        XCTAssertEqual(row?.status, .warn)
        XCTAssertEqual(row?.title, "2 other sessions are open in Claude and Alpha. Quitting closes them.")
        let one = engine(FakeWorld(running: [origID]), alive: { $0 == me })
        let p1 = one.preflight(sessions: entries(one, "local_aaaa0003"), to: toAlphaA, allowQuit: true)
        XCTAssertEqual(p1.items[0].rows.first { $0.kind == .others }?.title, "\"Old archived thing\" is open in Claude. Quitting closes it.")
    }

    // MARK: Quit & Move

    func testQuitAndMoveWithBothCopiesRunning() throws {
        let world = FakeWorld(running: [origID, alphaID])
        let e = engine(world)
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001", "local_aaaa0002"), to: toAlphaA, allowQuit: true)
        let events = Events()
        let outcome = try e.performWithQuit(plan) { step, state in events.add("\(step)-\(state)") }
        XCTAssertEqual(outcome.record.state, .done)
        XCTAssertEqual(Set(world.quits), [origID, alphaID])
        XCTAssertEqual(Set(world.reopens), [origID, alphaID])
        XCTAssertEqual(world.running, [origID, alphaID], "both are back")
        XCTAssertTrue(outcome.reopenFailed.isEmpty)
        XCTAssertEqual(outcome.record.reopen.map { Set($0.map(\.bundleID)) }, [origID, alphaID])
        XCTAssertTrue(exists("\(alpha)/\(ctx)/local_aaaa0001.json"))
        XCTAssertFalse(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
        let order = events.all.filter { $0.hasSuffix("running") }
        XCTAssertEqual(order, ["quit-running", "backup-running", "moveFiles-running", "lease-running", "verify-running", "reopen-running"])
        XCTAssertEqual(events.all.last, "reopen-done")
        XCTAssertEqual(e.history().first?.record.state, .done)
    }

    func testNoReopenOption() throws {
        let world = FakeWorld(running: [origID, alphaID])
        let e = engine(world)
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        try e.performWithQuit(plan, reopen: false)
        XCTAssertTrue(world.running.isEmpty)
        XCTAssertTrue(world.reopens.isEmpty)
    }

    func testOnlyRunningCopiesAreQuit() throws {
        let world = FakeWorld(running: [alphaID])
        let e = engine(world)
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        try e.performWithQuit(plan)
        XCTAssertEqual(world.quits, [alphaID])
        XCTAssertEqual(world.reopens, [alphaID], "a copy that wasn't running stays closed")
    }

    func testCopyThatDoesNotQuitChangesNothingAndReopensTheOthers() throws {
        let world = FakeWorld(running: [origID, alphaID])
        world.failQuit = [origID]
        let e = engine(world)
        let before = snapshot()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        XCTAssertThrowsError(try e.performWithQuit(plan)) { err in
            guard case MoveError.didntQuit(let name) = err else { return XCTFail("\(err)") }
            XCTAssertEqual(name, "Claude")
            XCTAssertEqual(err.localizedDescription, "Claude didn't quit.")
        }
        XCTAssertEqual(diff(before, snapshot()), [])
        XCTAssertEqual(world.reopens, [alphaID], "the one already quit comes back")
        XCTAssertEqual(world.running, [origID, alphaID])
        XCTAssertTrue(e.history().isEmpty)
    }

    func testStopDuringQuitChangesNothing() throws {
        let world = FakeWorld(running: [origID, alphaID])
        let token = CancelToken()
        world.onQuit = { _ in token.cancel() }
        let e = engine(world)
        let before = snapshot()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        XCTAssertThrowsError(try e.performWithQuit(plan, cancel: token)) { err in
            guard case MoveError.cancelled = err else { return XCTFail("\(err)") }
        }
        XCTAssertEqual(diff(before, snapshot()), [])
        XCTAssertEqual(world.running, [origID, alphaID])
        XCTAssertTrue(e.history().isEmpty)
    }

    func testStopDuringBackUpLeavesNoJournal() throws {
        let token = CancelToken()
        let e = engine(FakeWorld())
        let before = snapshot()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        token.cancel()
        XCTAssertThrowsError(try e.perform(plan, cancelled: { token.isCancelled })) { err in
            guard case MoveError.cancelled = err else { return XCTFail("\(err)") }
        }
        XCTAssertEqual(diff(before, snapshot()), [])
        XCTAssertTrue(e.history().isEmpty)
    }

    func testProcessThatSurvivesTheQuitStopsTheMove() throws {
        let world = FakeWorld(running: [origID, alphaID])
        world.stuckReal = [origID]    // the .real process outlives NSRunningApplication
        let e = engine(world)
        let before = snapshot()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        XCTAssertThrowsError(try e.performWithQuit(plan)) { err in
            guard case MoveError.blocked(let rows) = err else { return XCTFail("\(err)") }
            XCTAssertEqual(rows.first?.kind, .apps)
        }
        XCTAssertEqual(diff(before, snapshot()), [])
        XCTAssertTrue(e.history().isEmpty)
        XCTAssertEqual(world.reopens, [alphaID], "what was quit is reopened (Claude still has a process, so it counts as running)")
    }

    func testFailureAfterFilesMovedRollsBackAndReopens() throws {
        let world = FakeWorld(running: [origID, alphaID])
        let e = engine(world)
        e.injectFailure = { $0 == "lease" }
        let before = snapshot()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        XCTAssertThrowsError(try e.performWithQuit(plan)) { err in
            guard case MoveError.rolledBack = err else { return XCTFail("\(err)") }
        }
        XCTAssertEqual(diff(before, snapshot()), [])
        XCTAssertEqual(world.running, [origID, alphaID])
        XCTAssertEqual(e.history().first?.record.state, .rolledBack)
    }

    func testReopenFailureIsReportedButTheMoveIsDone() throws {
        let world = FakeWorld(running: [origID, alphaID])
        world.failReopen = [alphaID]
        let e = engine(world)
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        let outcome = try e.performWithQuit(plan)
        XCTAssertEqual(outcome.record.state, .done)
        XCTAssertEqual(outcome.reopenFailed.map(\.name), ["Alpha"])
        XCTAssertTrue(exists("\(alpha)/\(ctx)/local_aaaa0001.json"))
    }

    func testAllowlistStopsTheQuit() throws {
        let world = FakeWorld(running: [origID, alphaID])
        let e = engine(world, policy: WritePolicy(allowed: .slugs(["alpha"])))
        let plan = MovePlan(destination: toAlphaA, destinationInstance: nil, items: [], destinationPhrase: "")
        XCTAssertThrowsError(try e.performWithQuit(plan))
        XCTAssertTrue(world.quits.isEmpty)
        // A hand-made plan for a copy that isn't allowed never reaches the controller.
        let p = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA, allowQuit: true)
        XCTAssertFalse(p.canMove)
        XCTAssertThrowsError(try e.performWithQuit(p))
        XCTAssertTrue(world.quits.isEmpty)
    }

    func testSystemControllerRefusesCopiesTheAllowlistDoesNotPermit() throws {
        // The real controller: the policy check runs before anything is looked up, quit or opened.
        let c = SystemAppController(policy: WritePolicy(allowed: .slugs(["test1", "test2"])))
        let catalog = InstanceCatalog(env: fx.env).load()
        let refs = catalog.map(InstanceRef.init)
        XCTAssertFalse(refs.isEmpty)
        for r in refs {
            XCTAssertThrowsError(try c.quit(r, cancelled: { false }), r.name) { XCTAssertEqual($0 as? AppControlError, .notAllowed(r.name)) }
            XCTAssertThrowsError(try c.reopen(r), r.name) { XCTAssertEqual($0 as? AppControlError, .notAllowed(r.name)) }
        }
        for slug in ["default", "work", "client", "lab"] { XCTAssertFalse(WritePolicy.current(env: fx.env, processEnv: [:]).allows(slug: slug)) }
        // The default engine builds its controller with the engine's policy.
        let engine = MoveEngine(env: fx.env, running: NoApps(), realProcesses: NoRealProcesses(), policy: WritePolicy(allowed: .slugs(["test1"])))
        XCTAssertThrowsError(try engine.appController.quit(refs[0], cancelled: { false }))
    }

    // MARK: Recovery

    static let steps = ["backup", "writeDestination", "group", "idx", "sideFiles", "lease", "verify", "deleteSource"]

    /// A clean move of the same two sessions in its own fixture, for comparison.
    func cleanResult() throws -> [String: String] {
        let f = try makeFixture()
        defer { f.cleanup() }
        let e = engine(FakeWorld(), fx: f)
        let lib = e.scanner.scan()
        let src = ["local_aaaa0001", "local_aaaa0002"].map { id in lib.allEntries.first { $0.id == id }! }
        try e.perform(e.preflight(sessions: src, to: toAlphaA))
        return snapshot(f)
    }

    func crash(at step: String, world: FakeWorld = FakeWorld(), quitting: Bool = false) throws -> MoveEngine {
        let e = engine(world)
        e.crashHook = { $0 == step }
        let src = entries(e, "local_aaaa0001", "local_aaaa0002")
        let plan = e.preflight(sessions: src, to: toAlphaA, allowQuit: quitting)
        XCTAssertTrue(plan.canMove, "\(plan.rows)")
        XCTAssertThrowsError(try { if quitting { _ = try e.performWithQuit(plan) } else { _ = try e.perform(plan) } }(), step) { err in
            guard case MoveError.simulatedCrash(let s) = err else { return XCTFail("\(step): \(err)") }
            XCTAssertEqual(s, step)
        }
        return e
    }

    func testKillAtEveryStepIsRecoveredByFinishOrRollBack() throws {
        let clean = try cleanResult()
        for step in Self.steps {
            fx.cleanup(); fx = try makeFixture()
            let before = snapshot()
            _ = try crash(at: step)
            if step != "backup" { XCTAssertNotEqual(diff(before, snapshot()), [], "\(step): the crash left something half-done") }

            // a new process finds it
            let world = FakeWorld()
            let e = engine(world)
            let found = e.recoverableMoves()
            XCTAssertEqual(found.count, 1, step)
            XCTAssertEqual(found.first?.state, .started)
            XCTAssertEqual(found.first?.step, step, "the journal says where it stopped")

            XCTAssertTrue(e.canFinish(found[0]), step)
            let outcome = try e.finish(found[0])
            XCTAssertEqual(outcome.record.state, .done, step)
            XCTAssertEqual(diff(clean, snapshot()), [], "finishing after a kill at \(step) equals a clean move")
            XCTAssertTrue(e.recoverableMoves().isEmpty)
            XCTAssertEqual(e.history().first?.record.state, .done)

            // the other way out, from the same crash
            fx.cleanup(); fx = try makeFixture()
            let pristine = snapshot()
            _ = try crash(at: step)
            let e2 = engine(FakeWorld())
            let rolled = try e2.rollBack(e2.recoverableMoves()[0])
            XCTAssertEqual(rolled.record.state, .rolledBack, step)
            XCTAssertEqual(diff(pristine, snapshot()), [], "rolling back after a kill at \(step) is byte for byte")
            XCTAssertTrue(e2.recoverableMoves().isEmpty)
        }
    }

    func testRecoveryQuitsAndReopensTheCopiesAndRemembersWhatWasRunning() throws {
        // Quit & Move killed at the lease step: both apps were quit and never reopened.
        let world = FakeWorld(running: [origID, alphaID])
        _ = try crash(at: "lease", world: world, quitting: true)
        XCTAssertTrue(world.running.isEmpty, "the kill left both apps closed")
        let e = engine(world)
        let rec = e.recoverableMoves()[0]
        XCTAssertEqual(rec.reopen.map { Set($0.map(\.bundleID)) }, [origID, alphaID])
        let outcome = try e.finish(rec)
        XCTAssertEqual(world.running, [origID, alphaID], "Finish brings them back")
        XCTAssertEqual(outcome.record.state, .done)

        // And roll back, with one of them running now and the other not.
        fx.cleanup(); fx = try makeFixture()
        let w2 = FakeWorld(running: [origID, alphaID])
        _ = try crash(at: "verify", world: w2, quitting: true)
        w2.setRunning([alphaID])
        let e2 = engine(w2)
        let before = w2.quits.count
        let out2 = try e2.rollBack(e2.recoverableMoves()[0])
        XCTAssertEqual(w2.quits.count, before + 1, "only the running one is quit")
        XCTAssertEqual(w2.running, [origID, alphaID])
        XCTAssertEqual(out2.record.state, .rolledBack)
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
    }

    func testFinishRefusesWhenTheDestinationChanged() throws {
        _ = try crash(at: "idx")
        let e = engine(FakeWorld())
        let rec = e.recoverableMoves()[0]
        try fx.write(#"{"sessionId":"local_aaaa0001","title":"edited"}"#, "\(alpha)/\(ctx)/local_aaaa0001.json")
        XCTAssertNotNil(e.finishBlocker(for: rec))
        XCTAssertThrowsError(try e.finish(rec)) { guard case MoveError.cantFinish = $0 else { return XCTFail("\($0)") } }
        XCTAssertTrue(e.finishPlan(for: rec).isBlocked)
        // roll back is still possible
        XCTAssertEqual(try e.rollBack(rec).record.state, .rolledBack)
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
    }

    func testFinishWithABusySessionInARunningCopyBlocks() throws {
        _ = try crash(at: "lease")
        let me = getpid()
        try fx.write(#"{"pid":\#(me),"sessionId":"fe56159c-da13-4589-aa09-bbfd51cb6d4e","hostSessionId":"local_aaaa0002","status":"busy"}"#, ".claude/sessions/busy.json")
        let world = FakeWorld(running: [origID])
        let e = engine(world, alive: { $0 == me })
        let rec = e.recoverableMoves()[0]
        XCTAssertThrowsError(try e.finish(rec)) { err in
            guard case MoveError.blocked = err else { return XCTFail("\(err)") }
        }
        XCTAssertTrue(world.quits.isEmpty, "nothing is quit when something is busy")
    }

    func testUndoWithQuitUsesTheSameOrchestration() throws {
        let e0 = engine(FakeWorld())
        let rec = try e0.perform(e0.preflight(sessions: entries(e0, "local_aaaa0001"), to: toAlphaA))
        let world = FakeWorld(running: [origID, alphaID])
        let e = engine(world)
        XCTAssertTrue(e.restorePlan(for: rec).isBlocked, "plain undo still blocks while a copy runs")
        let plan = e.restorePlan(for: rec, allowQuit: true)
        XCTAssertFalse(plan.isBlocked)
        XCTAssertEqual(plan.rows.first { $0.kind == .apps }?.title, "Alpha and Claude are open. They quit, then reopen after the restore.")
        let out = try e.undoWithQuit(rec)
        XCTAssertEqual(out.record.state, .undone)
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
        XCTAssertFalse(exists("\(alpha)/\(ctx)/local_aaaa0001.json"))
        XCTAssertEqual(world.running, [origID, alphaID])
    }

    // MARK: Replace

    func testReplaceBacksUpTheExistingEntryAndUndoBringsItBack() throws {
        try fx.write(#"{"sessionId":"local_aaaa0001","title":"older copy at the destination"}"#, "\(alpha)/\(ctx)/local_aaaa0001.json")
        let e = engine(FakeWorld())
        let src = entries(e, "local_aaaa0001").filter { $0.instanceID == origID }
        let blocked = e.preflight(sessions: src, to: toAlphaA)
        XCTAssertFalse(blocked.canMove)
        XCTAssertTrue(blocked.hasDuplicates)
        let plan = e.preflight(sessions: src, to: toAlphaA, replace: true)
        XCTAssertTrue(plan.canMove, "\(plan.items[0].blocks)")
        XCTAssertEqual(plan.buttonTitle, "Replace")
        XCTAssertEqual(plan.items[0].rows.first { $0.kind == .destination }?.status, .warn)
        let old = try Data(contentsOf: url("\(alpha)/\(ctx)/local_aaaa0001.json"))
        let rec = try e.perform(plan)
        let now = try JSONSerialization.jsonObject(with: Data(contentsOf: url("\(alpha)/\(ctx)/local_aaaa0001.json"))) as! [String: Any]
        XCTAssertEqual(now["title"] as? String, "Fix export regex")
        XCTAssertFalse(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
        _ = try e.undo(rec)
        XCTAssertEqual(try Data(contentsOf: url("\(alpha)/\(ctx)/local_aaaa0001.json")), old, "the replaced entry is back byte for byte")
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
    }

    // MARK: Open a copy

    func testCopyPlanRows() throws {
        let e = engine(FakeWorld())
        let src = entries(e, "local_aaaa0003")[0]
        let plan = e.copyPlan(entry: src, to: MoveDestination(instanceID: alphaID))
        XCTAssertTrue(plan.canCopy, "\(plan.rows)")
        XCTAssertTrue(plan.rows.contains { $0.kind == .folder && $0.status == .warn && $0.title == "The copy will ask for a different folder." })
        XCTAssertEqual(plan.dstAccountID, Fixture.acctB, "opens in the account Alpha is signed in to")
        // another account than the destination's signed-in one can't be asked for
        let other = e.copyPlan(entry: src, to: toAlphaA)
        XCTAssertTrue(other.blocks.contains { $0.title.contains("signed in to a different account") })
        // the destination is Beta: not signed in, no app installed
        let beta = e.copyPlan(entry: src, to: MoveDestination(instanceID: "com.anthropic.claudefordesktop-beta"))
        XCTAssertTrue(beta.isBlocked)
        // allowlist
        let off = engine(FakeWorld(), policy: WritePolicy(allowed: .slugs(["test1"])))
        XCTAssertTrue(off.copyPlan(entry: src, to: MoveDestination(instanceID: alphaID)).blocks.contains { $0.kind == .allowlist })
        // already in the same account of the same copy
        XCTAssertTrue(e.copyPlan(entry: src, to: MoveDestination(instanceID: origID)).blocks.contains { $0.title.hasPrefix("Already in") })
        // running apps don't matter: nothing quits
        let running = engine(FakeWorld(running: [origID, alphaID]))
        XCTAssertTrue(running.copyPlan(entry: src, to: MoveDestination(instanceID: alphaID)).canCopy)
        // an earlier copy at the destination warns, never blocks
        try fx.write(#"{"sessionId":"local_copy0001","cliSessionId":"3152f529-8a3f-4550-aca5-1ef8deef4421","cwd":"/tmp","title":"x"}"#,
                     ".claude-profiles/alpha/Library/Application Support/Claude/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgX)/local_copy0001.json")
        let again = e.copyPlan(entry: src, to: MoveDestination(instanceID: alphaID))
        XCTAssertTrue(again.canCopy)
        XCTAssertTrue(again.warnings.contains { $0.title.hasPrefix("A copy of this session is already in") })
    }

    func testOpenACopyJournalsChipAndArchivesOnUndo() async throws {
        let world = FakeWorld(running: [alphaID])
        let e = engine(world)
        let src = entries(e, "local_aaaa0001")[0]
        let plan = e.copyPlan(entry: src, to: MoveDestination(instanceID: alphaID))
        XCTAssertTrue(plan.canCopy, "\(plan.rows)")
        let opener = await FakeOpener()
        let rec = try await e.performCopy(plan, launcher: CopyLauncher(workspace: opener))
        let opened = await opener.opened
        XCTAssertEqual(opened.map(\.0.absoluteString), ["claude://resume?session=\(Fixture.cliBusy)"])
        XCTAssertEqual(opened.map(\.1.lastPathComponent), ["Claude-alpha.app"], "aimed at the .app, never .real")
        XCTAssertEqual(rec.kind, "copy")
        XCTAssertEqual(rec.state, .done)
        XCTAssertTrue(world.quits.isEmpty, "a copy quits nothing")
        XCTAssertEqual(e.history().first?.record.id, rec.id)
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"), "the original stays")
        XCTAssertNil(rec.items[0].dstSHA256)
        XCTAssertTrue(e.recoverableMoves().isEmpty)

        // chip
        var settings = AppSettings()
        settings.addCopyMark(try XCTUnwrap(e.copyMark(for: rec)))
        try SettingsStore(env: fx.env).save(settings)
        let lib = e.scanner.scan()
        let row = lib.allEntries.first { $0.id == "local_aaaa0001" && $0.instanceID == origID }!
        XCTAssertTrue(lib.chips(for: row).contains(.copied("Alpha")))
        XCTAssertEqual(StateChip.copied("Alpha").title, "Copied")
        XCTAssertFalse(lib.chips(for: lib.allEntries.first { $0.id == "local_aaaa0002" }!).contains(.copied("Alpha")))

        // Undo with no copy there yet: nothing to archive
        XCTAssertTrue(e.restorePlan(for: rec, allowQuit: true).isBlocked)

        // Claude imported it: a new entry in Alpha with the same cliSessionId, made just now. An older one isn't ours.
        let folder = ".claude-profiles/alpha/Library/Application Support/Claude/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgX)"
        try fx.write(#"{"sessionId":"local_imported1","cliSessionId":"\#(Fixture.cliBusy)","cwd":"\#(fx.existingFolder)","title":"Fix export regex","isArchived":false,"keep":{"a":1}}"#, "\(folder)/local_imported1.json")
        try fx.write(#"{"sessionId":"local_older0001","cliSessionId":"\#(Fixture.cliBusy)","cwd":"\#(fx.existingFolder)","title":"old import","createdAt":1}"#, "\(folder)/local_older0001.json")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: url("\(folder)/local_older0001.json").path)
        try fx.write(#"{"v":1,"archived":[]}"#, "\(folder)/archived-sessions.idx")
        let olderBefore = try Data(contentsOf: url("\(folder)/local_older0001.json"))

        XCTAssertEqual(e.copyEntries(for: rec).map(\.id), ["local_imported1"])
        let plan2 = e.restorePlan(for: rec, allowQuit: true)
        XCTAssertFalse(plan2.isBlocked, "\(plan2.rows)")
        XCTAssertEqual(plan2.rows.first { $0.kind == .apps }?.title, "Alpha is open. It quits, then reopens after the archive.")
        XCTAssertTrue(e.restorePlan(for: rec).isBlocked, "plain undo blocks while Alpha runs")

        let out = try e.undoWithQuit(rec)
        XCTAssertEqual(out.record.state, .undone)
        XCTAssertEqual(world.quits, [alphaID])
        XCTAssertEqual(world.reopens, [alphaID])
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url("\(folder)/local_imported1.json"))) as! [String: Any]
        XCTAssertEqual(d["isArchived"] as? Bool, true, "archived, not deleted")
        XCTAssertEqual((d["keep"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(try json("\(folder)/archived-sessions.idx")["archived"] as? [String], ["local_imported1"])
        XCTAssertEqual(try Data(contentsOf: url("\(folder)/local_older0001.json")), olderBefore, "an older entry is left alone")
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
        XCTAssertEqual(e.history().first?.record.state, .undone)
        XCTAssertEqual(URL(fileURLWithPath: out.record.items[0].dstPath).resolvingSymlinksInPath(), url("\(folder)/local_imported1.json").resolvingSymlinksInPath())
        XCTAssertTrue(e.restorePlan(for: out.record).blocks.contains { $0.title == "The copy is already archived." })
        XCTAssertGreaterThan(out.record.files.count, 0, "the files were backed up before archiving")

        // marks go away
        settings.removeCopyMarks(moveID: rec.id)
        XCTAssertTrue(settings.copied.isEmpty)
    }

    func testImportedCopyWithTheSameLocalIdIsFoundAndArchived() async throws {
        let world = FakeWorld(running: [alphaID])
        let e = engine(world)
        let src = entries(e, "local_aaaa0001")[0]
        let plan = e.copyPlan(entry: src, to: MoveDestination(instanceID: alphaID))
        let rec = try await e.performCopy(plan, launcher: CopyLauncher(workspace: FakeOpener()))
        let folder = ".claude-profiles/alpha/Library/Application Support/Claude/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgX)"
        try fx.write(#"{"sessionId":"local_aaaa0001","cliSessionId":"\#(Fixture.cliBusy)","cwd":"\#(fx.existingFolder)","title":"Fix export regex"}"#, "\(folder)/local_aaaa0001.json")
        XCTAssertEqual(e.copyEntries(for: rec).map(\.fileURL.lastPathComponent), ["local_aaaa0001.json"])
        XCTAssertEqual(e.copyEntries(for: rec).first?.instanceID, alphaID, "the source in Claude is not picked")
        XCTAssertFalse(e.restorePlan(for: rec, allowQuit: true).isBlocked)
        // a second plan now warns about the existing copy, never blocks
        XCTAssertTrue(e.copyPlan(entry: src, to: MoveDestination(instanceID: alphaID)).warnings.contains { $0.title.hasPrefix("A copy of this session is already in") })
        let out = try e.undoWithQuit(rec)
        XCTAssertEqual(out.record.state, .undone)
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url("\(folder)/local_aaaa0001.json"))) as! [String: Any]
        XCTAssertEqual(d["isArchived"] as? Bool, true)
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: url("\(orig)/\(ctx)/local_aaaa0001.json"))) as! [String: Any]
        XCTAssertNil(source["isArchived"], "the source is untouched")
        // chip stays on the source row only
        var settings = AppSettings(); settings.addCopyMark(e.copyMark(for: rec)!)
        try SettingsStore(env: fx.env).save(settings)
        let lib = e.scanner.scan()
        for entry in lib.allEntries where entry.id == "local_aaaa0001" {
            XCTAssertEqual(lib.chips(for: entry).contains(.copied("Alpha")), entry.instanceID == origID)
        }
    }

    func testCopyUndoRefusesAnUnallowedCopy() throws {
        let e0 = engine(FakeWorld())
        var rec = try e0.journalCopy(e0.copyPlan(entry: entries(e0, "local_aaaa0001")[0], to: MoveDestination(instanceID: alphaID)),
                                     destination: e0.scanner.scan().instance(alphaID)!)
        rec.state = .done
        let world = FakeWorld(running: [alphaID])
        let e = engine(world, policy: WritePolicy(allowed: .slugs(["test1"])))
        XCTAssertTrue(e.restorePlan(for: rec, allowQuit: true).blocks.contains { $0.kind == .allowlist })
        XCTAssertThrowsError(try e.undoWithQuit(rec))
        XCTAssertTrue(world.quits.isEmpty)
    }

    func json(_ rel: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url(rel))) as! [String: Any] }

    func testSettingsRoundTripAndOldFilesStillLoad() throws {
        var s = AppSettings()
        s.addCopyMark(CopiedMark(sourceID: "local_a", sourceBundleID: "b1", destBundleID: "b2", destName: "Two", createdAt: Date(timeIntervalSince1970: 100), moveID: "m1"))
        s.addCopyMark(CopiedMark(sourceID: "local_a", sourceBundleID: "b1", destBundleID: "b2", destName: "Two", createdAt: Date(timeIntervalSince1970: 200), moveID: "m2"))
        XCTAssertEqual(s.copied.count, 1, "a second copy to the same place replaces the mark")
        try SettingsStore(env: fx.env).save(s)
        XCTAssertEqual(SettingsStore(env: fx.env).load().copied, s.copied)
        try fx.write(#"{"firstRunCompleted":true}"#, "Library/Application Support/SessionMover/settings.json")
        XCTAssertEqual(SettingsStore(env: fx.env).load().copied, [])
    }

    func testMoveStepLists() {
        XCTAssertEqual(MoveStep.orchestrated.count, 6)
        XCTAssertEqual(MoveStep.plain, [.backup, .moveFiles, .lease, .verify])
        XCTAssertTrue(MoveStep.quit.canStop && MoveStep.backup.canStop && !MoveStep.moveFiles.canStop)
    }
}

extension FakeWorld {
    func setRunning(_ ids: Set<String>) { lockedSet(ids) }
}

@MainActor
final class FakeOpener: WorkspaceOpening {
    var opened: [(URL, URL)] = []
    func open(_ url: URL, withApplicationAt appURL: URL) async throws { opened.append((url, appURL)) }
    func reveal(_ url: URL) {}
}
