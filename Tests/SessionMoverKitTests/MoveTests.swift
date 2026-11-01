import XCTest
@testable import SessionMoverKit

struct FakeReal: RealProcessChecking {
    var paths: Set<String>
    func hasRealProcess(appURL: URL) -> Bool { paths.contains(appURL.lastPathComponent) }
}

final class MoveTests: XCTestCase {
    var fx: Fixture!
    let orig = "Library/Application Support/Claude"
    let alpha = ".claude-profiles/alpha/Library/Application Support/Claude"
    let origID = "com.anthropic.claudefordesktop"
    let alphaID = "com.anthropic.claudefordesktop-alpha"
    var ctx: String { "claude-code-sessions/\(Fixture.acctA)/\(Fixture.orgX)" }

    override func setUpWithError() throws {
        fx = try Fixture()
        let dir = fx.existingFolder
        // aaaa0001: every field a move rewrites, plus unknown ones, a worktree and a side-session
        try fx.write(#"{"sessionId":"local_aaaa0001","cliSessionId":"\#(Fixture.cliBusy)","cwd":"\#(dir)","originCwd":"\#(dir)","createdAt":1,"lastActivityAt":2,"title":"Fix export regex","cliBinaryPin":{"version":"2.1.309"},"remoteMcpServersConfig":[{"uuid":"u1","name":"Docs"}],"unknownField":{"a":[1,2],"b":null},"worktreeName":"wt-one","worktreePath":"\#(dir)/wt","branch":"claude/x","brandNew":"keep me"}"#,
                     "\(orig)/\(ctx)/local_aaaa0001.json")
        try fx.write(#"{"schemaVersion":2,"worktrees":{"wt-one":{"leasedBy":"local_aaaa0001","branch":"claude/x","adopted":true,"nested":{"k":[1,2]}},"wt-other":{"leasedBy":"local_zzzz"}},"futureKey":"stay"}"#,
                     "\(orig)/git-worktrees.json")
        try fx.write(#"{"preferences":{"epitaxyPrefs":{"starred-local-code-sessions":["local_aaaa0002"],"dframe-group-scopes":{"\#(Fixture.acctA)/\#(Fixture.orgX)":{"groups":[{"id":"cg-1","name":"Group One","mode":"code"}],"assignments":{"code:local_aaaa0001":"cg-1","code:local_other":"cg-1"},"order":{"cg-1":["code:local_aaaa0001","code:local_other"]}}}},"keepMe":1}}"#,
                     "\(orig)/\(MoveEngine.prefsFile)")
        try fx.write("{\"s\":1}", "\(orig)/\(ctx)/waiting-input/local_aaaa0001.json")
        try fx.write("note", "\(orig)/side-session-notes/local_aaaa0001/notes.md")
        try fx.write("untouched", "\(orig)/\(ctx)/scheduled-tasks.json")
    }
    override func tearDown() { fx.cleanup() }

    // MARK: Helpers

    /// Every engine here gets a fake `AppControlling`: a test never quits or opens a real app.
    func engine(apps: RunningAppsProviding = NoApps(), real: RealProcessChecking = NoRealProcesses(),
                policy: WritePolicy = .all, verified: Set<String> = ["4.29.0", "4.30.1"],
                controller: AppControlling? = nil,
                alive: @escaping @Sendable (Int32) -> Bool = { _ in false }) -> MoveEngine {
        var labels = AccountLabels(); labels.setAccount(Fixture.acctB, name: "Team")
        let e = MoveEngine(env: fx.env, running: apps, realProcesses: real, policy: policy,
                           formatGuard: FormatGuard(verified: verified), labels: labels,
                           appController: controller ?? FakeWorld(), isPIDAlive: alive)
        e.settleTimeout = 0
        return e
    }

    func entries(_ e: MoveEngine, _ ids: String...) -> [SessionEntry] {
        let lib = e.scanner.scan()
        return ids.map { id in lib.allEntries.first { $0.id == id }! }
    }
    func entry(_ e: MoveEngine, _ id: String, in instance: String) -> SessionEntry {
        e.scanner.scan().allEntries.first { $0.id == id && $0.instanceID == instance }!
    }

    var toAlphaA: MoveDestination { MoveDestination(instanceID: alphaID, accountID: Fixture.acctA) }
    func url(_ rel: String) -> URL { fx.home.appendingPathComponent(rel) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url(rel).path) }
    func json(_ rel: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url(rel))) as! [String: Any] }

    /// Every file and folder under the fake home (except our own backups), with hash and mode.
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        let home = fx.home.resolvingSymlinksInPath()
        let skip = home.appendingPathComponent("Library/Application Support/SessionMover").path
        let en = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey])!
        while let raw = en.nextObject() as? URL {
            let u = raw.resolvingSymlinksInPath()
            if u.path.hasPrefix(skip) { continue }
            let rel = String(u.path.dropFirst(home.path.count))
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { out[rel] = "dir"; continue }
            let mode = MoveFiles.mode(of: u).map { String($0, radix: 8) } ?? "?"
            out[rel] = "\(MoveFiles.sha256(of: u) ?? "?") \(mode)"
        }
        return out
    }

    func diff(_ a: [String: String], _ b: [String: String]) -> [String] {
        var out: [String] = []
        for k in Set(a.keys).union(b.keys).sorted() where a[k] != b[k] {
            out.append("\(k.suffix(70)): \(a[k].map { String($0.prefix(12)) } ?? "absent") -> \(b[k].map { String($0.prefix(12)) } ?? "absent")")
        }
        return out
    }

    // MARK: Same account, copy to copy

    func testSameAccountCopyToCopy() throws {
        let e = engine()
        let src = entries(e, "local_aaaa0001")
        let plan = e.preflight(sessions: src, to: toAlphaA)
        XCTAssertTrue(plan.canMove, "\(plan.items[0].blocks)")
        XCTAssertEqual(plan.items[0].leaseNames, ["wt-one"])
        let rec = try e.perform(plan)
        XCTAssertEqual(rec.state, .done)
        XCTAssertFalse(exists("\(orig)/\(ctx)/local_aaaa0001.json"), "source removed")
        let d = try json("\(alpha)/\(ctx)/local_aaaa0001.json")
        XCTAssertNil(d["cliBinaryPin"])
        XCTAssertEqual((d["remoteMcpServersConfig"] as? [[String: Any]])?.count, 1, "same org keeps connectors")
        XCTAssertEqual(d["brandNew"] as? String, "keep me")
        XCTAssertNotNil((d["unknownField"] as? [String: Any])?["b"] as? NSNull)
        XCTAssertEqual(d["worktreeName"] as? String, "wt-one")

        // lease moved with every field and mode 0600; other leases and keys stay
        let dwt = try json("\(alpha)/git-worktrees.json")
        let lease = (dwt["worktrees"] as? [String: Any])?["wt-one"] as? [String: Any]
        XCTAssertEqual(lease?["leasedBy"] as? String, "local_aaaa0001")
        XCTAssertEqual(lease?["adopted"] as? Bool, true)
        XCTAssertEqual(dwt["schemaVersion"] as? Int, 2)
        XCTAssertEqual(MoveFiles.mode(of: url("\(alpha)/git-worktrees.json")), 0o600)
        XCTAssertEqual(MoveFiles.mode(of: url("\(orig)/git-worktrees.json")), 0o600)
        let swt = try json("\(orig)/git-worktrees.json")
        XCTAssertNil((swt["worktrees"] as? [String: Any])?["wt-one"])
        XCTAssertNotNil((swt["worktrees"] as? [String: Any])?["wt-other"])
        XCTAssertEqual(swt["futureKey"] as? String, "stay")
        XCTAssertEqual(MoveFiles.mode(of: url("\(alpha)/\(ctx)/local_aaaa0001.json")), 0o600)

        // group assignment and definition moved; the other session's assignment stayed
        let scopes = { (rel: String) throws -> [String: Any] in
            (((try self.json(rel)["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])?["dframe-group-scopes"] as? [String: Any]) ?? [:] }
        let ds = try scopes("\(alpha)/\(MoveEngine.prefsFile)")[ "\(Fixture.acctA)/\(Fixture.orgX)"] as? [String: Any]
        XCTAssertEqual((ds?["assignments"] as? [String: Any])?["code:local_aaaa0001"] as? String, "cg-1")
        XCTAssertEqual(((ds?["groups"] as? [[String: Any]])?.first)?["name"] as? String, "Group One")
        let ss = try scopes("\(orig)/\(MoveEngine.prefsFile)")["\(Fixture.acctA)/\(Fixture.orgX)"] as? [String: Any]
        XCTAssertNil((ss?["assignments"] as? [String: Any])?["code:local_aaaa0001"])
        XCTAssertEqual((ss?["assignments"] as? [String: Any])?["code:local_other"] as? String, "cg-1")
        XCTAssertEqual((ss?["order"] as? [String: Any])?["cg-1"] as? [String], ["code:local_other"])
        XCTAssertEqual((try json("\(orig)/\(MoveEngine.prefsFile)")["preferences"] as? [String: Any])?["keepMe"] as? Int, 1)

        // side files
        XCTAssertFalse(exists("\(orig)/\(ctx)/waiting-input/local_aaaa0001.json"))
        XCTAssertTrue(exists("\(alpha)/\(ctx)/waiting-input/local_aaaa0001.json"))
        XCTAssertTrue(exists("\(alpha)/side-session-notes/local_aaaa0001/notes.md"))
        XCTAssertTrue(exists("\(orig)/side-session-notes/local_aaaa0001/notes.md"), "notes are copied, not moved")
        XCTAssertEqual(try String(contentsOf: url("\(orig)/\(ctx)/scheduled-tasks.json")), "untouched")

        // journal and history
        let h = e.history()
        XCTAssertEqual(h.map(\.record.id), [rec.id])
        XCTAssertEqual(h[0].record.state, .done)
        XCTAssertGreaterThan(h[0].backupBytes, 0)
        XCTAssertEqual(MoveFiles.mode(of: fx.env.settingsDir.appendingPathComponent("backups/\(rec.id)/journal.json")), 0o600)
        // no leftover temp files
        let en = FileManager.default.enumerator(at: fx.home, includingPropertiesForKeys: nil)!
        while let u = en.nextObject() as? URL { XCTAssertFalse(u.lastPathComponent.hasSuffix(".tmp") && u.lastPathComponent.hasPrefix(".sm-"), u.path) }
    }

    func testUnchangedEntryIsCopiedByteForByte() throws {
        let e = engine()
        let src = entries(e, "local_bbbb0001") // no pin, no connectors
        let before = try Data(contentsOf: src[0].fileURL)
        // Alpha (signed in B) to the original copy, account A: other account, same org X -> nothing to rewrite
        let dest = MoveDestination(instanceID: origID, accountID: Fixture.acctA)
        let rec = try e.perform(e.preflight(sessions: src, to: dest))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: rec.items[0].dstPath)), before)
    }

    // MARK: Cross account, cross org

    func testCrossAccountSameCopy() throws {
        let e = engine()
        let src = entries(e, "local_bbbb0001")             // alpha, account B, org X
        let plan = e.preflight(sessions: src, to: toAlphaA) // alpha, account A
        XCTAssertTrue(plan.canMove, "\(plan.items[0].blocks)")
        XCTAssertEqual(plan.items[0].dstOrgID, Fixture.orgX)
        try e.perform(plan)
        XCTAssertFalse(exists("\(alpha)/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgX)/local_bbbb0001.json"))
        XCTAssertTrue(exists("\(alpha)/\(ctx)/local_bbbb0001.json"))
    }

    func testCrossOrgNullsConnectorsAndDropsPin() throws {
        try fx.write(#"{"sessionId":"local_bbbb0002","cliSessionId":"9696094d-11ea-45fb-ab9f-03627bcaedd4","cwd":"\#(fx.existingFolder)","title":"x","cliBinaryPin":{"v":1},"remoteMcpServersConfig":[{"uuid":"u1"}],"future":[1,{"z":2}]}"#,
                     "\(alpha)/\(ctx)/local_bbbb0002.json")
        let e = engine()
        let src = [entry(e, "local_bbbb0002", in: alphaID)]
        let dest = MoveDestination(instanceID: alphaID, accountID: Fixture.acctA, orgID: Fixture.orgY)
        let plan = e.preflight(sessions: src, to: dest)
        XCTAssertTrue(plan.canMove, "\(plan.items[0].blocks)")
        XCTAssertTrue(plan.items[0].rows.contains { $0.kind == .org && $0.status == .warn })
        try e.perform(plan)
        let d = try json("\(alpha)/claude-code-sessions/\(Fixture.acctA)/\(Fixture.orgY)/local_bbbb0002.json")
        XCTAssertTrue(d["remoteMcpServersConfig"] is NSNull)
        XCTAssertNil(d["cliBinaryPin"])
        XCTAssertEqual((d["future"] as? [Any])?.count, 2)
        XCTAssertFalse(exists("\(alpha)/\(ctx)/local_bbbb0002.json"))
    }

    func testUsageLimitErrorCleared() throws {
        let e = engine()
        let src = entries(e, "local_aaaa0003") // has a session-limit error
        let plan = e.preflight(sessions: src, to: toAlphaA)
        XCTAssertTrue(plan.items[0].rows.contains { $0.kind == .limit && $0.status == .warn })
        XCTAssertTrue(plan.items[0].rows.contains { $0.kind == .folder && $0.status == .warn })
        let rec = try e.perform(plan)
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: rec.items[0].dstPath))) as! [String: Any]
        XCTAssertNil(d["error"])
        XCTAssertEqual(d["title"] as? String, "Hit the limit")
    }

    // MARK: Archive index

    func testArchivedSessionUpdatesBothIndexes() throws {
        try fx.write(#"{"v":1,"archived":[]}"#, "\(alpha)/\(ctx)/archived-sessions.idx")
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0002"), to: toAlphaA)
        XCTAssertTrue(plan.canMove, "\(plan.items[0].blocks)")
        try e.perform(plan)
        XCTAssertEqual(try json("\(orig)/\(ctx)/archived-sessions.idx")["archived"] as? [String], [])
        XCTAssertEqual(try json("\(alpha)/\(ctx)/archived-sessions.idx")["archived"] as? [String], ["local_aaaa0002"])
        XCTAssertEqual(try String(contentsOf: url("\(alpha)/\(ctx)/archived-sessions.idx")), #"{"v":1,"archived":["local_aaaa0002"]}"#)
    }

    func testPinnedAcrossAccountsWarns() throws {
        let e = engine()
        let dest = MoveDestination(instanceID: alphaID) // signed in to B; session is in A
        let plan = e.preflight(sessions: entries(e, "local_aaaa0002"), to: dest)
        XCTAssertTrue(plan.items[0].rows.contains { $0.kind == .pinned && $0.status == .warn })
        let same = e.preflight(sessions: entries(e, "local_aaaa0002"), to: toAlphaA)
        XCTAssertFalse(same.items[0].rows.contains { $0.kind == .pinned })
    }

    // MARK: Blocks

    func testDuplicateAtDestinationBlocks() throws {
        try fx.write("{}", "\(alpha)/\(ctx)/local_aaaa0001.json")
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertFalse(plan.canMove)
        XCTAssertTrue(plan.items[0].isDuplicate)
        XCTAssertEqual(plan.items[0].blocks.first?.title, "Already in Alpha · account \(AccountLabels.shortID(Fixture.acctA))")
        XCTAssertThrowsError(try e.perform(plan))

        // a duplicate in another account of the same copy blocks a cross-copy move, too
        try FileManager.default.removeItem(at: url("\(alpha)/\(ctx)/local_aaaa0001.json"))
        try fx.write("{}", "\(alpha)/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgX)/local_aaaa0001.json")
        let plan2 = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertTrue(plan2.items[0].isDuplicate)
        XCTAssertEqual(plan2.items[0].blocks.first?.title, "Already in Team account".replacingOccurrences(of: "Already in ", with: "Already in Alpha · "))
    }

    func testMovingWithinSameAccountBlocks() throws {
        let e = engine()
        let dest = MoveDestination(instanceID: origID, accountID: Fixture.acctA, orgID: Fixture.orgX)
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: dest)
        XCTAssertFalse(plan.canMove)
        XCTAssertFalse(plan.items[0].isDuplicate)
    }

    func testBusySessionBlocks() throws {
        let me = getpid()
        let e = engine(alive: { $0 == me })
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertFalse(plan.canMove)
        XCTAssertTrue(plan.items[0].blocks.contains { $0.kind == .state && $0.title.contains("is busy") })
    }

    func testIdleOpenSessionWarnsWhenCopyRunsAndBlocksWhenItDoesNot() throws {
        let me = getpid()
        try fx.write(#"{"pid":\#(me),"sessionId":"3af5413f-ad2d-4f03-a684-3026a900f317","hostSessionId":"local_aaaa0002","status":"idle"}"#, ".claude/sessions/idle.json")
        let e1 = engine(alive: { $0 == me })
        let p1 = e1.preflight(sessions: entries(e1, "local_aaaa0002"), to: toAlphaA)
        XCTAssertTrue(p1.items[0].blocks.contains { $0.title.contains("open in a terminal") })
        let e2 = engine(apps: FakeApps(ids: [origID]), alive: { $0 == me })
        let p2 = e2.preflight(sessions: entries(e2, "local_aaaa0002"), to: toAlphaA)
        XCTAssertTrue(p2.items[0].rows.contains { $0.kind == .state && $0.status == .warn && $0.title == "Open in Claude. Quitting closes it." })
        XCTAssertTrue(p2.items[0].blocks.contains { $0.kind == .apps })
    }

    func testRunningCopyBlocks() throws {
        let src = { (e: MoveEngine) in self.entries(e, "local_aaaa0001") }
        var e = engine(apps: FakeApps(ids: [alphaID]))
        var plan = e.preflight(sessions: src(e), to: toAlphaA)
        XCTAssertEqual(plan.items[0].blocks.first { $0.kind == .apps }?.title, "Quit Alpha first.")
        XCTAssertFalse(plan.canMove)
        e = engine(apps: FakeApps(ids: [origID, alphaID]))
        plan = e.preflight(sessions: src(e), to: toAlphaA)
        XCTAssertEqual(plan.items[0].blocks.first { $0.kind == .apps }?.title, "Quit Claude and Alpha first.")
        // a .real process with no NSRunningApplication still counts
        e = engine(real: FakeReal(paths: ["Claude.app"]))
        plan = e.preflight(sessions: src(e), to: toAlphaA)
        XCTAssertEqual(plan.items[0].blocks.first { $0.kind == .apps }?.title, "Quit Claude first.")
    }

    func testUnverifiedVersionBlocks() throws {
        let e = engine(verified: ["4.29.0"]) // Alpha is 4.30.1
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertEqual(plan.items[0].blocks.first { $0.kind == .version }?.title, "Alpha 4.30.1 isn't verified yet.")
        XCTAssertFalse(plan.canMove)
        XCTAssertTrue(FormatGuard.standard.isVerified("4.29.0"))
        XCTAssertFalse(FormatGuard.standard.isVerified("4.29.1"))
        XCTAssertFalse(FormatGuard.standard.isVerified(nil))
    }

    func testAllowlistBlocksEitherSide() throws {
        var e = engine(policy: WritePolicy(allowed: .slugs(["alpha"])))
        var plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertEqual(plan.items[0].blocks.first { $0.kind == .allowlist }?.title, "Moving into or out of Claude is turned off.")
        XCTAssertThrowsError(try e.perform(plan))
        e = engine(policy: WritePolicy(allowed: .slugs(["default"])))
        plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertEqual(plan.items[0].blocks.first { $0.kind == .allowlist }?.title, "Moving into or out of Alpha is turned off.")
        XCTAssertFalse(plan.canMove)
        // perform refuses even with a hand-made plan
        var forced = plan; forced.items[0].rows = []
        XCTAssertThrowsError(try e.perform(forced)) // fresh preflight blocks it
    }

    func testWritePolicySources() throws {
        // default
        XCTAssertEqual(WritePolicy.current(env: fx.env, processEnv: [:]).allowed, .slugs(["test1", "test2"]))
        XCTAssertFalse(WritePolicy.current(env: fx.env, processEnv: [:]).allows(slug: "default"))
        // settings.json
        var s = AppSettings(); s.writableInstances = ["Alpha", "default"]
        try SettingsStore(env: fx.env).save(s)
        let p = WritePolicy.current(env: fx.env, processEnv: [:])
        XCTAssertTrue(p.allows(slug: "alpha")); XCTAssertTrue(p.allows(slug: "default")); XCTAssertFalse(p.allows(slug: "test1"))
        XCTAssertEqual(SettingsStore(env: fx.env).load().writableInstances, ["Alpha", "default"], "round-trips through settings")
        // env wins
        XCTAssertEqual(WritePolicy.current(env: fx.env, processEnv: ["SM_ALLOW": "all"]).allowed, .all)
        XCTAssertEqual(WritePolicy.current(env: fx.env, processEnv: ["SM_ALLOW": "test1, test2"]).allowed, .slugs(["test1", "test2"]))
        XCTAssertTrue(WritePolicy.current(env: fx.env, processEnv: ["SM_ALLOW": "x,all"]).allows(slug: "anything"))
        XCTAssertEqual(AppSettings().writableInstances, nil)
    }

    func testNotSignedInAndMissingFolder() throws {
        let e = engine()
        let beta = MoveDestination(instanceID: "com.anthropic.claudefordesktop-beta")
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: beta)
        XCTAssertFalse(plan.canMove)
        XCTAssertTrue(plan.items[0].blocks.contains { $0.kind == .destination })
    }

    func testFamilyAndSeveralOrgsAndStaleSelection() throws {
        try fx.write(#"{"sessionId":"local_aaaa0004","cwd":"\#(fx.existingFolder)","title":"child","spawnedFrom":{"sessionId":"local_aaaa0001"}}"#, "\(orig)/\(ctx)/local_aaaa0004.json")
        let e = engine()
        let one = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertTrue(one.items[0].rows.contains { $0.kind == .family && $0.status == .warn && $0.detail?.contains("child") == true })
        let both = e.preflight(sessions: entries(e, "local_aaaa0001", "local_aaaa0004"), to: toAlphaA)
        XCTAssertFalse(both.items.contains { $0.rows.contains { $0.kind == .family } }, "moving together: nothing stays behind")
        // a selection that no longer exists on disk
        let stale = entries(e, "local_aaaa0001")
        try FileManager.default.removeItem(at: stale[0].fileURL)
        XCTAssertFalse(e.preflight(sessions: stale, to: toAlphaA).canMove)
    }

    func testLeaseConflictBlocks() throws {
        try fx.write(#"{"schemaVersion":2,"worktrees":{"wt-one":{"leasedBy":"local_someoneelse"}}}"#, "\(alpha)/git-worktrees.json")
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        XCTAssertTrue(plan.items[0].blocks.contains { $0.kind == .lease })
    }

    // MARK: Several sessions

    func testSeveralSessionsSkipsBlocked() throws {
        try fx.write("{}", "\(alpha)/\(ctx)/local_aaaa0002.json") // duplicate for one of three
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001", "local_aaaa0002", "local_aaaa0003"), to: toAlphaA)
        XCTAssertEqual(plan.movable.count, 2)
        XCTAssertEqual(plan.blocked.count, 1)
        XCTAssertEqual(plan.buttonTitle, "Move 2, Skip 1")
        let dest = plan.rows.first { $0.kind == .destination }!
        XCTAssertEqual(dest.status, .block)
        XCTAssertTrue(dest.title.contains("1 of 3") || dest.title.contains("(1 of 3)"), dest.title)
        let rec = try e.perform(plan)
        XCTAssertEqual(rec.items.count, 2)
        XCTAssertTrue(exists("\(alpha)/\(ctx)/local_aaaa0003.json"))
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0002.json"), "the skipped one stays")
    }

    // MARK: Failure and rollback

    func testFailureAtEveryStepRollsBackByteForByte() throws {
        try fx.write(#"{"v":1,"archived":["local_aaaa0001"]}"#, "\(orig)/\(ctx)/archived-sessions.idx")
        try fx.write(#"{"v":1,"archived":[]}"#, "\(alpha)/\(ctx)/archived-sessions.idx")
        var s = try String(contentsOf: url("\(orig)/\(ctx)/local_aaaa0001.json"))
        s = s.replacingOccurrences(of: "\"brandNew\"", with: "\"isArchived\":true,\"brandNew\"")
        try fx.write(s, "\(orig)/\(ctx)/local_aaaa0001.json")
        let before = snapshot()
        for step in ["backup", "writeDestination", "lease", "group", "idx", "sideFiles", "verify", "deleteSource"] {
            let e = engine()
            e.injectFailure = { $0 == step }
            let plan = e.preflight(sessions: entries(e, "local_aaaa0001", "local_aaaa0002"), to: toAlphaA)
            XCTAssertTrue(plan.canMove, step)
            XCTAssertThrowsError(try e.perform(plan), step) { err in
                if step == "backup" { guard case MoveError.failedBeforeChanges = err else { return XCTFail("\(err)") } }
                else { guard case MoveError.rolledBack = err else { return XCTFail("\(step): \(err)") } }
            }
            XCTAssertEqual(diff(before, snapshot()), [], "rolled back after failure at \(step)")
            if step != "backup" { XCTAssertEqual(e.history().first?.record.state, .rolledBack, step) }
        }
    }

    // MARK: Undo

    func testUndoRestoresEveryFileByteForByte() throws {
        try fx.write(#"{"v":1,"archived":["local_aaaa0002"]}"#, "\(orig)/\(ctx)/archived-sessions.idx")
        try fx.write(#"{"v":1,"archived":[]}"#, "\(alpha)/\(ctx)/archived-sessions.idx")
        let before = snapshot()
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001", "local_aaaa0002"), to: toAlphaA)
        let rec = try e.perform(plan)
        XCTAssertNotEqual(snapshot(), before)

        // every backed-up file matches its pre-move hash after undo
        let undone = try e.undo(rec)
        XCTAssertEqual(undone.state, .undone)
        XCTAssertEqual(diff(before, snapshot()), [])
        for f in rec.files where f.existed {
            XCTAssertEqual(MoveFiles.sha256(of: URL(fileURLWithPath: f.path)), f.sha256, f.path)
        }
        XCTAssertEqual(e.history().first?.record.state, .undone)
        // twice is blocked
        XCTAssertThrowsError(try e.undo(rec))
    }

    func testUndoRemovesFoldersTheMoveCreated() throws {
        // destination org folder does not exist yet
        let before = snapshot()
        let e = engine()
        let dest = MoveDestination(instanceID: alphaID, accountID: "5da54b2c-3145-4fb1-a3db-50f3d4f77dc5", orgID: Fixture.orgX)
        let rec = try e.perform(e.preflight(sessions: entries(e, "local_aaaa0001"), to: dest))
        XCTAssertTrue(exists("\(alpha)/claude-code-sessions/5da54b2c-3145-4fb1-a3db-50f3d4f77dc5/\(Fixture.orgX)/local_aaaa0001.json"))
        try e.undo(rec)
        XCTAssertEqual(diff(before, snapshot()), [])
    }

    func testUndoChecks() throws {
        let e = engine()
        let rec = try e.perform(e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA))

        // copy running
        let running = engine(apps: FakeApps(ids: [alphaID]))
        XCTAssertTrue(running.restorePlan(for: rec).blocks.contains { $0.kind == .apps && $0.title == "Quit Alpha first." })
        XCTAssertThrowsError(try running.undo(rec))

        // busy where it is now
        let me = getpid()
        try fx.write(#"{"pid":\#(me),"sessionId":"\#(Fixture.cliBusy)","hostSessionId":"local_aaaa0001","status":"busy"}"#, ".claude/sessions/b.json")
        let busy = engine(alive: { $0 == me })
        XCTAssertTrue(busy.restorePlan(for: rec).blocks.contains { $0.title.contains("is busy") })
        try FileManager.default.removeItem(at: url(".claude/sessions/b.json"))

        // the source holds a newer entry with that id
        try fx.write(#"{"sessionId":"local_aaaa0001","title":"newer"}"#, "\(orig)/\(ctx)/local_aaaa0001.json")
        XCTAssertTrue(e.restorePlan(for: rec).blocks.contains { $0.title.contains("newer entry") })
        XCTAssertThrowsError(try e.undo(rec))
        try FileManager.default.removeItem(at: url("\(orig)/\(ctx)/local_aaaa0001.json"))

        // destination used after the move: warn, still allowed
        try fx.write(#"{"sessionId":"local_aaaa0001","title":"used since"}"#, "\(alpha)/\(ctx)/local_aaaa0001.json")
        let plan = e.restorePlan(for: rec)
        XCTAssertFalse(plan.isBlocked)
        XCTAssertTrue(plan.rows.contains { $0.status == .warn && $0.title.contains("changed after the move") })
        // allowlist
        XCTAssertTrue(engine(policy: WritePolicy(allowed: .slugs(["test1"]))).restorePlan(for: rec).isBlocked)
        _ = try e.undo(rec)
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"))
        XCTAssertFalse(exists("\(alpha)/\(ctx)/local_aaaa0001.json"))
    }

    // MARK: History

    func testHistoryAndEmpty() throws {
        let e = engine()
        let r1 = try e.perform(e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA))
        let r2 = try e.perform(e.preflight(sessions: entries(e, "local_aaaa0002"), to: toAlphaA))
        XCTAssertEqual(e.history().map(\.record.id), [r2.id, r1.id])
        XCTAssertEqual(e.record(id: r1.id)?.items.first?.title, "Fix export regex")
        XCTAssertNil(e.record(id: "../x"))
        // an unfinished journal stays
        var unfinished = r1; unfinished.id = "20990101-000000-aaaaaa"; unfinished.state = .started
        let dir = e.backupsDir.appendingPathComponent(unfinished.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try e.writeJournal(unfinished, to: dir.appendingPathComponent("journal.json"))
        XCTAssertEqual(try e.emptyHistory(), 2)
        XCTAssertEqual(e.history().map(\.record.id), [unfinished.id])
        // sessions stay where they are
        XCTAssertTrue(exists("\(alpha)/\(ctx)/local_aaaa0001.json"))
        XCTAssertFalse(e.restorePlan(for: unfinished).blocks.contains { $0.title == "Already restored." })
    }

    // MARK: Destination parsing, rows

    func testParseDestination() throws {
        let lib = engine().scanner.scan()
        XCTAssertEqual(try MoveDestination.parse("alpha", in: lib).instanceID, alphaID)
        XCTAssertEqual(try MoveDestination.parse("default", in: lib).instanceID, origID)
        let d = try MoveDestination.parse("alpha/\(Fixture.acctA.prefix(8))/\(Fixture.orgY.prefix(6))", in: lib)
        XCTAssertEqual(d, MoveDestination(instanceID: alphaID, accountID: Fixture.acctA, orgID: Fixture.orgY))
        var labels = AccountLabels(); labels.setAccount(Fixture.acctB, name: "Team")
        XCTAssertEqual(try MoveDestination.parse("alpha/team", in: lib, labels: labels).accountID, Fixture.acctB)
        XCTAssertThrowsError(try MoveDestination.parse("nope", in: lib))
        XCTAssertThrowsError(try MoveDestination.parse("alpha/zzzz", in: lib))
    }

    func testPassRowsForACleanMove() throws {
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaA)
        let titles = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.kind, $0.title) })
        XCTAssertEqual(titles[.state], "Session isn't running")
        XCTAssertEqual(titles[.apps], "No apps need to quit")
        XCTAssertEqual(titles[.folder], "Working folder exists")
        XCTAssertEqual(titles[.lease], "Worktree lease moves with it")
        XCTAssertEqual(titles[.org], "Same organization")
        XCTAssertTrue(titles[.destination]?.hasPrefix("Not in Alpha") == true)
        XCTAssertEqual(plan.buttonTitle, "Move")
    }

    // MARK: Entry rewrite

    func testRewriteEntryRules() {
        let e: [String: Any] = ["a": 1, "cliBinaryPin": ["v": 1], "remoteMcpServersConfig": [["u": 1]], "error": "You've hit your usage limit", "errorAt": 5, "errorRows": [1], "other": ["x": [1, 2]]]
        let same = MoveEngine.rewriteEntry(e, sameOrg: true)
        XCTAssertNil(same.entry["cliBinaryPin"]); XCTAssertNil(same.entry["error"]); XCTAssertNil(same.entry["errorAt"]); XCTAssertNil(same.entry["errorRows"])
        XCTAssertNotNil(same.entry["remoteMcpServersConfig"] as? [Any])
        let other = MoveEngine.rewriteEntry(e, sameOrg: false)
        XCTAssertTrue(other.entry["remoteMcpServersConfig"] is NSNull)
        XCTAssertNotNil(other.entry["other"])
        XCTAssertFalse(MoveEngine.rewriteEntry(["a": 1], sameOrg: true).changed)
        XCTAssertEqual(MoveEngine.rewriteEntry(["error": "boom"], sameOrg: true).entry["error"] as? String, "boom", "a non-limit error stays")
    }

    func testTempNameNeverStartsWithLocal() throws {
        let dir = fx.home.appendingPathComponent("tmpcheck")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("local_x.json")
        try MoveFiles.writeAtomic(Data("{}".utf8), to: target)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["local_x.json"])
        XCTAssertEqual(MoveFiles.mode(of: target), 0o600)
    }
}
