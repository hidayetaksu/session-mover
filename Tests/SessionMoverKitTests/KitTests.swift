import XCTest
@testable import SessionMoverKit

struct NoApps: RunningAppsProviding { func isRunning(bundleID: String) -> Bool { false } }
struct FakeApps: RunningAppsProviding { var ids: Set<String>; func isRunning(bundleID: String) -> Bool { ids.contains(bundleID) } }

final class KitTests: XCTestCase {
    var fx: Fixture!
    override func setUpWithError() throws { fx = try Fixture() }
    override func tearDown() { fx.cleanup() }

    func scan(apps: RunningAppsProviding = NoApps()) -> Library {
        LibraryScanner(env: fx.env, running: apps).scan()
    }

    // MARK: InstanceCatalog

    func testCatalogOrderAndFields() {
        let list = InstanceCatalog(env: fx.env).load()
        XCTAssertEqual(list.map(\.name), ["Claude", "Alpha", "Beta", "Stray"])
        XCTAssertEqual(list[0].bundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(list[0].version, "4.29.0")
        let alpha = list[1]
        XCTAssertEqual(alpha.bundleID, "com.anthropic.claudefordesktop-alpha")
        XCTAssertEqual(alpha.accentHex, "#2563EB")
        XCTAssertEqual(alpha.iconName, "wrench.fill")
        XCTAssertEqual(alpha.version, "4.30.1", "version comes from the bundle, not profiles.json")
        XCTAssertTrue(alpha.dataURL.path.hasSuffix(".claude-profiles/alpha/Library/Application Support/Claude"))
        XCTAssertEqual(alpha.appURL.lastPathComponent, "Claude-alpha.app")
        XCTAssertFalse(list[2].appInstalled)
        XCTAssertFalse(list[2].dataFolderExists)
        XCTAssertEqual(list[3].origin, .discovered)
        XCTAssertFalse(list.contains { $0.bundleID.contains("madappgang") })
    }

    func testNoProfilesJSONStillFindsOriginal() throws {
        try FileManager.default.removeItem(at: fx.env.profilesJSON)
        XCTAssertEqual(InstanceCatalog(env: fx.env).load().first?.name, "Claude")
    }

    // MARK: Signed-in account and token safety

    func testSignedInAccountReadsOnlyTheUUID() {
        let lib = scan()
        XCTAssertEqual(lib.scan("com.anthropic.claudefordesktop")?.signedInAccountID, Fixture.acctA)
        XCTAssertEqual(lib.scan("com.anthropic.claudefordesktop-alpha")?.signedInAccountID, Fixture.acctB)
        XCTAssertNil(lib.scan("com.anthropic.claudefordesktop-beta")?.signedInAccountID)
    }

    func testTokenNeverSurfaces() throws {
        let lib = scan()
        var dump = String(reflecting: lib.instances)
        dump += String(reflecting: lib.liveSessions)
        XCTAssertFalse(dump.contains(Fixture.secret))
        XCTAssertFalse(dump.contains("tokenCache"))
        XCTAssertNil(SignedInAccount.extract(from: Data(#"{"lastKnownAccountUuid":"not-a-uuid"}"#.utf8)))
        XCTAssertNil(SignedInAccount.extract(from: Data(#"{"other":1}"#.utf8)))
    }

    // MARK: SessionIndex

    func testSessionCountsAndTolerance() {
        let lib = scan()
        let orig = lib.scan("com.anthropic.claudefordesktop")!
        // 3 entries + 1 broken; the .tmp file, scheduled-tasks.json and the idx are ignored
        XCTAssertEqual(orig.entries.count, 4)
        XCTAssertEqual(orig.unreadableCount, 1)
        let broken = orig.entries.first { $0.isUnreadable }!
        XCTAssertEqual(broken.displayTitle, "local_broken.json")
        XCTAssertNotNil(broken.readError)
        XCTAssertEqual(orig.orgs.count, 2, "an org folder with no entries is kept, not an error")
        XCTAssertEqual(orig.orgs.first { $0.orgID == Fixture.orgX }?.archivedHint, ["local_aaaa0002"])
        let alpha = lib.scan("com.anthropic.claudefordesktop-alpha")!
        XCTAssertEqual(alpha.entries.count, 3)
        XCTAssertEqual(Set(alpha.accountIDs), [Fixture.acctA, Fixture.acctB])
        XCTAssertEqual(alpha.accountIDs.first, Fixture.acctB, "signed-in account sorts first")
        XCTAssertEqual(lib.scan("com.anthropic.claudefordesktop-beta")?.entries.count, 0)
        XCTAssertNotNil(lib.scan("com.anthropic.claudefordesktop-beta")?.scanError)
        XCTAssertEqual(lib.allEntries.count, 7)
    }

    func testSummaryFieldsAndUnknownFieldsIgnored() {
        let e = scan().allEntries.first { $0.id == "local_aaaa0001" }!
        let s = e.summary!
        XCTAssertEqual(s.title, "Fix export regex")
        XCTAssertEqual(s.cliSessionId, Fixture.cliBusy)
        XCTAssertEqual(s.branch, "claude/fix-regex")
        XCTAssertEqual(s.prNumbers, [843])
        XCTAssertEqual(s.model, "claude-opus-5-5")
        XCTAssertEqual(s.lastActivityAt, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(s.folderExists, true)
    }

    func testDateParsing() {
        XCTAssertEqual(SummaryParser.date(NSNumber(value: 1_793_000_000_000)), Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(SummaryParser.date(NSNumber(value: 1_793_000_000)), Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(SummaryParser.date("1793000000000"), Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertNotNil(SummaryParser.date("2026-10-31T07:16:15.659Z"))
        XCTAssertNil(SummaryParser.date(NSNumber(value: true)))
    }

    func testRescanSeesNewFile() throws {
        let scanner = LibraryScanner(env: fx.env, running: NoApps())
        XCTAssertEqual(scanner.scan().allEntries.count, 7)
        try fx.entry(".claude-profiles/alpha/Library/Application Support/Claude/claude-code-sessions/\(Fixture.acctB)/\(Fixture.orgX)",
                     "local_bbbb0099", title: "New", cli: "1714ab38-dd7a-43ae-a4c1-fb17938f500b", cwd: fx.existingFolder, last: 1_793_400_000_000, extra: "")
        XCTAssertEqual(scanner.scan().allEntries.count, 8)
    }

    // MARK: LiveState

    func testLiveSessionsAndKeyFilesIgnored() {
        let live = LiveStateReader.readSessions(in: fx.env.claudeSessionsDir)
        XCTAssertEqual(Set(live.compactMap(\.hostSessionId)), ["local_aaaa0001", "local_bbbb0002"],
                       "dead pid skipped; .key file never read")
        let lib = scan()
        let byID = Dictionary(uniqueKeysWithValues: lib.allEntries.map { ($0.id, $0) })
        XCTAssertEqual(lib.chips(for: byID["local_aaaa0001"]!).first, .busy)
        XCTAssertFalse(lib.isLive(byID["local_aaaa0002"]!))
        XCTAssertFalse(lib.isLive(byID["local_bbbb0001"]!), "a .key file must not make a session running")
        XCTAssertEqual(lib.chips(for: byID["local_bbbb0002"]!).first, .running)
    }

    func testRunningApps() {
        let lib = scan(apps: FakeApps(ids: ["com.anthropic.claudefordesktop-alpha"]))
        XCTAssertTrue(lib.isRunning(lib.scan("com.anthropic.claudefordesktop-alpha")!.instance))
        XCTAssertFalse(lib.isRunning(lib.scan("com.anthropic.claudefordesktop")!.instance))
        XCTAssertTrue(lib.hasBusySession(lib.scan("com.anthropic.claudefordesktop")!.instance))
    }

    // MARK: Chips, scopes, queries

    func testChipsAndPriority() {
        let lib = scan()
        let byID = Dictionary(uniqueKeysWithValues: lib.allEntries.map { ($0.id, $0) })
        XCTAssertEqual(lib.chips(for: byID["local_aaaa0001"]!), [.busy, .prs(1)])
        XCTAssertEqual(lib.chips(for: byID["local_aaaa0002"]!), [.archived])
        XCTAssertEqual(lib.chips(for: byID["local_aaaa0003"]!), [.limit("1:30am"), .folderMissing])
        XCTAssertEqual(lib.chips(for: byID["local_broken"]!), [.unreadable])
    }

    func testScopesAndHidden() {
        let lib = scan()
        let alpha = "com.anthropic.claudefordesktop-alpha"
        XCTAssertEqual(lib.entries(in: .hidden).map(\.id).sorted(), ["local_bbbb0002", "local_bbbb0003"])
        XCTAssertEqual(lib.entries(in: .running).count, 2)
        XCTAssertEqual(lib.entries(in: .needsAttention).map(\.id).sorted(), ["local_aaaa0003", "local_broken"])
        XCTAssertEqual(lib.entries(in: .account(instance: alpha, account: Fixture.acctA)).count, 2)
        XCTAssertEqual(lib.entries(in: .org(instance: alpha, account: Fixture.acctA, org: Fixture.orgY)).count, 1)
        XCTAssertEqual(lib.entries(in: .instance(alpha)).count, 3)
    }

    func testFiltersSearchSortGroup() {
        let lib = scan()
        var q = SessionQuery()
        q.scope = .all
        XCTAssertEqual(lib.results(for: q).count, 5) // active: not archived, readable
        q.filter = .archived
        XCTAssertEqual(lib.results(for: q).map(\.id), ["local_aaaa0002"])
        q.filter = .errors
        XCTAssertEqual(lib.count(for: .errors, query: q), 2)
        q.filter = .all
        XCTAssertEqual(lib.results(for: q).count, 7)
        // search: title, folder, id, PR, scope switch
        q.search = "regex"; XCTAssertEqual(lib.results(for: q).map(\.id), ["local_aaaa0001"])
        q.search = "#843"; XCTAssertEqual(lib.results(for: q).map(\.id), ["local_aaaa0001"])
        q.search = "project one"; XCTAssertEqual(lib.results(for: q).count, 5)
        q.search = Fixture.cliBusy.prefix(8).description; XCTAssertEqual(lib.results(for: q).count, 1)
        q.search = "alpha"; q.scope = .instance("com.anthropic.claudefordesktop")
        XCTAssertEqual(lib.results(for: q).count, 0)
        q.searchAllInstances = true
        XCTAssertEqual(lib.results(for: q).count, 3)
        // sort + group
        q = SessionQuery(); q.filter = .all
        let sorted = lib.results(for: q)
        XCTAssertEqual(sorted.first?.id, "local_bbbb0003")
        let groups = Library.group(sorted)
        XCTAssertEqual(groups.first { $0.name == "project one" }?.entries.count, 5)
        XCTAssertTrue(groups.contains { $0.name == "folder" })
        XCTAssertTrue(groups.contains { $0.name == "Unreadable files" })
    }

    // MARK: AccountLabels

    func testLabelsRoundTripInSettingsFolderOnly() throws {
        let store = SettingsStore(env: fx.env)
        XCTAssertEqual(store.load(), AppSettings())
        var s = AppSettings()
        s.labels.setAccount(Fixture.acctA, name: "  you@example.com ")
        s.labels.setOrg(Fixture.orgX, name: "Team")
        s.firstRunCompleted = true
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        XCTAssertEqual(store.load().labels.display(account: Fixture.acctA), "you@example.com")
        XCTAssertEqual(store.load().labels.display(account: Fixture.acctB), "eb90b3bb")
        XCTAssertTrue(store.file.path.hasSuffix("Library/Application Support/SessionMover/settings.json"))
        s.labels.setAccount(Fixture.acctA, name: "")
        XCTAssertNil(s.labels.name(forAccount: Fixture.acctA))
        // unknown or partial settings files decode tolerantly
        try Data(#"{"labels":{"accounts":{"x":"y"}},"future":1}"#.utf8).write(to: store.file)
        XCTAssertEqual(store.load().labels.accounts["x"], "y")
    }

    // MARK: CopyLauncher

    @MainActor func testLauncherURLAndTarget() async throws {
        final class Spy: WorkspaceOpening {
            var opened: [(URL, URL)] = []; var revealed: [URL] = []
            func open(_ url: URL, withApplicationAt appURL: URL) async throws { opened.append((url, appURL)) }
            func reveal(_ url: URL) { revealed.append(url) }
        }
        XCTAssertEqual(CopyLauncher.resumeURL(cliSessionId: Fixture.cliBusy)?.absoluteString, "claude://resume?session=\(Fixture.cliBusy)")
        XCTAssertNil(CopyLauncher.resumeURL(cliSessionId: "x&evil=1"))
        let lib = scan()
        let spy = Spy()
        let launcher = CopyLauncher(workspace: spy)
        let e = lib.allEntries.first { $0.id == "local_bbbb0001" }!
        let inst = lib.instance(e.instanceID)!
        try await launcher.openInItsApp(e, in: inst)
        XCTAssertEqual(spy.opened.first?.1.lastPathComponent, "Claude-alpha.app")
        XCTAssertFalse(spy.opened.first!.1.path.hasSuffix(".real"))
        launcher.reveal(e)
        XCTAssertEqual(spy.revealed.first, e.fileURL)
        let beta = lib.instance("com.anthropic.claudefordesktop-beta")!
        do { try await launcher.openInItsApp(e, in: beta); XCTFail() } catch { XCTAssertEqual(error as? LaunchError, .appNotInstalled("Beta")) }
        let broken = lib.allEntries.first { $0.isUnreadable }!
        do { try await launcher.openInItsApp(broken, in: inst); XCTFail() } catch { XCTAssertEqual(error as? LaunchError, .noCliSessionId) }
    }

    // MARK: Misc

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(-30), now: now, calendar: cal), "Just now")
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(-120), now: now, calendar: cal), "2 min ago")
        XCTAssertEqual(RelativeTime.string(for: now.addingTimeInterval(-86400 * 40), now: now, calendar: cal).isEmpty, false)
    }

    func testFolderWatcherFires() throws {
        let dir = fx.root.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fired = expectation(description: "fsevents")
        fired.assertForOverFulfill = false
        let w = FolderWatcher(paths: [dir], latency: 0.2) { fired.fulfill() }
        XCTAssertNotNil(w)
        Thread.sleep(forTimeInterval: 0.5)
        try "x".write(to: dir.appendingPathComponent("local_new.json"), atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 10)
        w?.stop()
    }
}
