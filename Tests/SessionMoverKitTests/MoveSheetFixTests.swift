import XCTest
@testable import SessionMoverKit

final class MoveSheetFixTests: XCTestCase {
    var fx: Fixture!
    let orig = "Library/Application Support/Claude"
    let alpha = ".claude-profiles/alpha/Library/Application Support/Claude"
    let alphaID = "com.anthropic.claudefordesktop-alpha"
    static let orgW = "7094b0a1-ec43-4bb1-a5b0-4addfd95ac03"

    override func setUpWithError() throws { fx = try Fixture() }
    override func tearDown() { fx.cleanup() }

    func engine(policy: WritePolicy = .all) -> MoveEngine {
        let e = MoveEngine(env: fx.env, running: NoApps(), realProcesses: NoRealProcesses(), policy: policy,
                           formatGuard: FormatGuard(verified: ["4.29.0", "4.30.1"]), labels: AccountLabels(),
                           appController: FakeWorld(), isPIDAlive: { _ in false })
        e.settleTimeout = 0
        return e
    }
    func entries(_ e: MoveEngine, _ ids: String...) -> [SessionEntry] {
        let lib = e.scanner.scan()
        return ids.map { id in lib.allEntries.first { $0.id == id }! }
    }
    func toAlphaB(_ org: String? = nil) -> MoveDestination { MoveDestination(instanceID: alphaID, accountID: Fixture.acctB, orgID: org) }

    func testBothCopiesDisallowedGivesOneRowNamingBoth() throws {
        let e = engine(policy: WritePolicy(allowed: .slugs([])))
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaB())
        let rows = plan.items[0].rows.filter { $0.kind == .allowlist }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Moving into or out of Claude and Alpha is turned off.")
        XCTAssertEqual(rows[0].detail, "Turn them on in Settings ▸ Moves.")
        let agg = plan.rows.first { $0.kind == .allowlist }!
        XCTAssertTrue(agg.affected.isEmpty, "a single session lists no bullets")
    }

    func testAffectedHasNoDuplicateTitlesForSeveralSessions() throws {
        let e = engine(policy: WritePolicy(allowed: .slugs([])))
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001", "local_aaaa0003"), to: toAlphaB())
        let agg = plan.rows.first { $0.kind == .allowlist }!
        XCTAssertEqual(agg.affected.count, Set(agg.affected).count)
        XCTAssertEqual(agg.affected.count, 2)
        XCTAssertEqual(agg.title, "Moving into or out of Claude and Alpha is turned off.")
    }

    func testRestorePlanHasOneAllowlistRow() throws {
        var e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: MoveDestination(instanceID: alphaID, accountID: Fixture.acctA))
        let rec = try e.perform(plan)
        e = engine(policy: WritePolicy(allowed: .slugs([])))
        let rows = e.restorePlan(for: rec).rows.filter { $0.kind == .allowlist }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Moving into or out of Alpha and Claude is turned off.")
    }

    /// A session whose org (W) exists nowhere in the destination account.
    func addSourceInOrgW() throws {
        try fx.entry("\(orig)/claude-code-sessions/\(Fixture.acctA)/\(Self.orgW)", "local_cccc0001", title: "Org W session",
                     cli: "28c8852f-5fb5-4656-a73c-7063168a5c99", cwd: fx.existingFolder, last: 1_793_400_000_000, extra: "")
    }

    func testSourceOrgAmongSeveralIsAutoPicked() throws {
        // alpha, account B: orgX (1 entry) and orgY (empty). The session's org X is there.
        try FileManager.default.createDirectory(at: fx.home.appendingPathComponent("\(alpha)/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgY)"), withIntermediateDirectories: true)
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_aaaa0001"), to: toAlphaB())
        XCTAssertEqual(plan.items[0].dstOrgID, Fixture.orgX)
        XCTAssertTrue(plan.items[0].rows.contains { $0.kind == .org && $0.title == "Same organization" })
        XCTAssertTrue(plan.canMove)
    }

    func testOneNonEmptyOrgIsPickedOverEmptyOne() throws {
        try addSourceInOrgW()
        try FileManager.default.createDirectory(at: fx.home.appendingPathComponent("\(alpha)/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgY)"), withIntermediateDirectories: true)
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_cccc0001"), to: toAlphaB())
        XCTAssertEqual(plan.items[0].dstOrgID, Fixture.orgX)
        XCTAssertTrue(plan.orgChoices.isEmpty)
        XCTAssertTrue(plan.canMove)
    }

    func testTwoNonEmptyOrgsBlockWithChoices() throws {
        try addSourceInOrgW()
        try fx.entry("\(alpha)/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgY)", "local_dddd0001", title: "Other",
                     cli: "45de0d49-15c2-4805-a6ec-58f607ef8c98", cwd: fx.existingFolder, last: 1_793_500_000_000, extra: "")
        let e = engine()
        let plan = e.preflight(sessions: entries(e, "local_cccc0001"), to: toAlphaB())
        XCTAssertFalse(plan.canMove)
        XCTAssertNil(plan.items[0].dstOrgID)
        XCTAssertEqual(Set(plan.orgChoices.map(\.orgID)), [Fixture.orgX, Fixture.orgY])
        XCTAssertEqual(plan.orgChoices.map(\.entryCount), [1, 1])
        XCTAssertEqual(plan.rows.first { $0.kind == .destination }?.orgChoices.count, 2)
        // choosing one re-runs the checks with that org
        let chosen = e.preflight(sessions: entries(e, "local_cccc0001"), to: toAlphaB(Fixture.orgY))
        XCTAssertEqual(chosen.items[0].dstOrgID, Fixture.orgY)
        XCTAssertTrue(chosen.canMove)
    }
}
