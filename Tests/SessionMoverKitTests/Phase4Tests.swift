import XCTest
@testable import SessionMoverKit

/// Phase 4: multi-select moves, FormatGuard fingerprints, the bundled version list, settings.
extension MoveTests {
    // MARK: Multi-select

    /// Three sessions, one of them busy: the sheet row reads "2 of 3", the button "Move 2, Skip 1", the move
    /// carries the other two, and one Undo puts both back byte for byte.
    func testMultiSessionMoveWithBusyOneSkippedAndUndone() throws {
        let me = getpid()
        let e = engine(alive: { $0 == me })
        let src = entries(e, "local_aaaa0001", "local_aaaa0002", "local_aaaa0003")
        let before = snapshot()

        let plan = e.preflight(sessions: src, to: toAlphaA)
        XCTAssertEqual(plan.movable.count, 2)
        XCTAssertEqual(plan.blocked.map(\.entry.id), ["local_aaaa0001"])
        XCTAssertEqual(plan.buttonTitle, "Move 2, Skip 1")
        let state = try XCTUnwrap(plan.rows.first { $0.kind == .state })
        XCTAssertEqual(state.status, .block)
        XCTAssertTrue(state.title.contains("1 of 3") || state.title.contains("(1 of 3)"), state.title)
        XCTAssertEqual(state.affected, ["Fix export regex"])

        let rec = try e.perform(plan)
        XCTAssertEqual(rec.items.count, 2)
        XCTAssertTrue(exists("\(orig)/\(ctx)/local_aaaa0001.json"), "the busy one stays")
        XCTAssertFalse(exists("\(orig)/\(ctx)/local_aaaa0002.json"))
        XCTAssertTrue(exists("\(alpha)/\(ctx)/local_aaaa0003.json"))

        _ = try e.undo(rec)
        XCTAssertEqual(diff(before, snapshot()), [])
    }

    // MARK: FormatGuard

    func testBundledVersionsLoadFromResource() throws {
        let bundled = FormatGuard.bundled["4.29.0"]
        XCTAssertNotNil(bundled, "Resources/verified-versions.json wasn't found")
        let keys = Set(bundled?.topLevelKeys ?? [])
        XCTAssertGreaterThan(keys.count, 80, "the 4.29.0 fingerprint holds about 90 entry keys")
        for k in ["sessionId", "cliSessionId", "title", "cwd", "lastActivityAt", "isArchived", "remoteMcpServersConfig", "cliBinaryPin"] {
            XCTAssertTrue(keys.contains(k), k)
        }
        XCTAssertTrue(FormatGuard.standard.isVerified("4.29.0"))
        XCTAssertFalse(FormatGuard.standard.isVerified("4.29.1"))
    }

    /// Fingerprint of the fixture's own keys, minus `unknownField`: the scan reports exactly that key, by name.
    func testReportListsUnknownKeysByNameOnly() throws {
        let e = engine()
        let all: Set<String> = ["sessionId", "cliSessionId", "cwd", "originCwd", "createdAt", "lastActivityAt", "title", "model",
                                "permissionMode", "branch", "prs", "isArchived", "isStarred", "error", "cliBinaryPin",
                                "remoteMcpServersConfig", "worktreeName", "worktreePath", "brandNew"]
        let guardian = FormatGuard(versions: ["4.29.0": VerifiedVersion(topLevelKeys: Array(all))])
        let lib = e.scanner.scan()
        let scan = try XCTUnwrap(lib.scan(origID))
        let report = guardian.report(for: scan)
        XCTAssertTrue(report.verified)
        XCTAssertTrue(report.hasFingerprint)
        XCTAssertEqual(report.comparedWith, "4.29.0")
        XCTAssertEqual(report.unknownKeys, ["unknownField": 1])
        XCTAssertEqual(report.unreadable, 1, "the broken entry")
        XCTAssertGreaterThanOrEqual(report.entriesRead, 3)
    }

    func testUnverifiedCopyIsComparedWithNewestVerifiedFingerprint() throws {
        let e = engine()
        let guardian = FormatGuard(versions: [
            "4.28.0": VerifiedVersion(topLevelKeys: ["sessionId"]),
            "4.29.0": VerifiedVersion(topLevelKeys: ["sessionId", "title", "cwd", "cliSessionId"])])
        XCTAssertEqual(guardian.reference(for: "9.9.9")?.version, "4.29.0")
        XCTAssertEqual(guardian.reference(for: "4.28.0")?.version, "4.28.0")
        XCTAssertEqual(guardian.unknownKeys(["sessionId", "zzz"], version: "9.9.9"), ["zzz"])
        // No fingerprint anywhere: nothing can be told apart.
        let bare = FormatGuard(verified: ["4.29.0"])
        XCTAssertNil(bare.reference(for: "9.9.9"))
        XCTAssertEqual(bare.unknownKeys(["zzz"], version: "4.29.0"), [])
        let lib = e.scanner.scan()
        let alphaScan = try XCTUnwrap(lib.scan(alphaID)) // 4.30.1
        let r = guardian.report(for: alphaScan)
        XCTAssertFalse(r.verified)
        XCTAssertEqual(r.comparedWith, "4.29.0")
    }

    func testUnverifiedPhraseMatchesTheBannerAndTheSheet() throws {
        let lib = engine().scanner.scan()
        let alphaInst = try XCTUnwrap(lib.instance(alphaID))
        XCTAssertEqual(FormatGuard.unverifiedPhrase(alphaInst), "Alpha 4.30.1 isn't verified yet")
        XCTAssertEqual(FormatGuard(verified: ["4.29.0"]).blockMessage(for: alphaInst), "Alpha 4.30.1 isn't verified yet.")
    }

    // MARK: Settings and policy

    func testMenuBarSettingDefaultsOnAndRoundTrips() throws {
        var s = AppSettings()
        XCTAssertTrue(s.menuBarExtraEnabled)
        s.showMenuBarExtra = false
        let store = SettingsStore(env: fx.env)
        try store.save(s)
        XCTAssertFalse(store.load().menuBarExtraEnabled)
        XCTAssertTrue(AppSettings().menuBarExtraEnabled)
    }

    func testPolicyFollowsSettingsAndUpdates() throws {
        XCTAssertEqual(WritePolicy.settingsList(enabling: ["Test2", "test1"]), ["test1", "test2"])
        var s = AppSettings()
        s.writableInstances = WritePolicy.settingsList(enabling: ["alpha"])
        try SettingsStore(env: fx.env).save(s)
        let p = WritePolicy.current(env: fx.env, processEnv: [:])
        XCTAssertTrue(p.allows(slug: "alpha"))
        XCTAssertFalse(p.allows(slug: "test1"))
        XCTAssertEqual(WritePolicy.current(env: SMEnvironment(home: fx.root.appendingPathComponent("empty")), processEnv: [:]).summary, "test1, test2")
        XCTAssertTrue(WritePolicy.isOverriddenByEnvironment(["SM_ALLOW": "all"]))
        XCTAssertFalse(WritePolicy.isOverriddenByEnvironment([:]))

        // The engine's preflight follows updatePolicy.
        let e = engine(policy: WritePolicy(allowed: .slugs(["test1"])))
        var plan = e.preflight(sessions: entries(e, "local_aaaa0002"), to: toAlphaA)
        XCTAssertTrue(plan.items[0].blocks.contains { $0.kind == .allowlist })
        e.updatePolicy(WritePolicy(allowed: .slugs(["default", "alpha"])))
        plan = e.preflight(sessions: entries(e, "local_aaaa0002"), to: toAlphaA)
        XCTAssertFalse(plan.items[0].blocks.contains { $0.kind == .allowlist })
    }
}
