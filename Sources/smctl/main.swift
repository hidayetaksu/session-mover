import Foundation
import SessionMoverKit

// smctl: command line view of the same data the Session Mover app shows, plus moves.
//   smctl list [--json] [--counts]
//   smctl check
//   smctl formatguard
//   smctl move <local_id>... --to <slug>[/<account>[/<org>]] [--from <slug>] [--dry-run] [--replace] [--quit [--no-reopen]]
//   smctl copy <local_id> --to <slug>[/<account>] [--from <slug>] [--dry-run]
//   smctl history
//   smctl recover [<move id> --finish | --roll-back] [--no-reopen]
//   smctl undo <move id> [--quit [--no-reopen]]
// SM_HOME points every home path at another tree (fixtures, tests).
// Moves only write into, and only quit or reopen, copies the write allowlist permits: SM_ALLOW, else settings.json
// "writableInstances", else test1 and test2. Without --quit a running copy blocks; with --quit it is quit (a normal
// quit, never forced), the move runs, and it is reopened. `copy` opens a copy through Claude's deep link: nothing quits.
// SM_TEST_CRASH_AT=<step> (backup, writeDestination, group, idx, sideFiles, lease, verify, deleteSource) makes this
// process exit(9) right after that step is journaled, to test recovery. Only smctl honours it.

struct Out {
    static func line(_ s: String = "") { print(s) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}

func chipText(_ chips: [StateChip]) -> String {
    chips.isEmpty ? "" : chips.map { "[\($0.title)]" }.joined(separator: " ")
}

// MARK: JSON model

struct JSession: Encodable { var id: String; var title: String; var chips: [String]; var cliSessionId: String?; var archived: Bool; var unreadable: Bool }
struct JOrg: Encodable { var id: String; var sessions: Int; var items: [JSession] }
struct JAccount: Encodable { var id: String; var label: String?; var signedInNow: Bool; var sessions: Int; var orgs: [JOrg] }
struct JInstance: Encodable { var name: String; var bundleId: String; var version: String?; var running: Bool; var signedInAccount: String?; var sessions: Int; var error: String?; var accounts: [JAccount] }

func buildJSON(_ lib: Library, labels: AccountLabels) -> [JInstance] {
    lib.instances.map { scan in
        let accounts = scan.accountIDs.map { a -> JAccount in
            let orgs = scan.orgs.filter { $0.accountID == a }.map { o in
                JOrg(id: o.orgID, sessions: o.entries.count, items: o.entries.map { e in
                    JSession(id: e.id, title: e.displayTitle, chips: lib.chips(for: e).map(\.title),
                             cliSessionId: e.summary?.cliSessionId, archived: e.summary?.isArchived ?? false, unreadable: e.isUnreadable)
                })
            }
            return JAccount(id: a, label: labels.name(forAccount: a), signedInNow: a == scan.signedInAccountID,
                            sessions: orgs.reduce(0) { $0 + $1.sessions }, orgs: orgs)
        }
        return JInstance(name: scan.instance.name, bundleId: scan.instance.bundleID, version: scan.instance.version,
                         running: lib.isRunning(scan.instance), signedInAccount: scan.signedInAccountID,
                         sessions: scan.entries.count, error: scan.scanError, accounts: accounts)
    }
}

// MARK: list

func runList(_ args: [String], env: SMEnvironment) {
    let lib = LibraryScanner(env: env).scan()
    let labels = SettingsStore(env: env).load().labels
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(buildJSON(lib, labels: labels)), as: UTF8.self))
        return
    }
    let countsOnly = args.contains("--counts")
    for scan in lib.instances {
        let i = scan.instance
        var meta = [i.bundleID]
        if let v = i.version { meta.append(v) }
        meta.append(lib.isRunning(i) ? "running" : "not running")
        Out.line("\(i.name)  (\(meta.joined(separator: " · ")))  \(scan.entries.count) sessions")
        if let e = scan.scanError { Out.line("  ! \(e)") }
        for a in scan.accountIDs {
            let now = a == scan.signedInAccountID ? "  (signed in now)" : "  (hidden in \(i.name))"
            let total = scan.entries.filter { $0.accountID == a }.count
            Out.line("  account \(labels.name(forAccount: a).map { "\($0) " } ?? "")\(AccountLabels.shortID(a))\(now)  \(total) sessions")
            for o in scan.orgs where o.accountID == a {
                Out.line("    org \(AccountLabels.shortID(o.orgID))  \(o.entries.count) sessions")
                if countsOnly { continue }
                for e in o.entries {
                    let chips = chipText(lib.chips(for: e))
                    Out.line("      \(e.id)  \(e.displayTitle)\(chips.isEmpty ? "" : "  " + chips)")
                }
            }
        }
    }
    if lib.instances.isEmpty { Out.line("No Claude copies found.") }
}

// MARK: check

func shell(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func runCheck(env: SMEnvironment) -> Int32 {
    let lib = LibraryScanner(env: env).scan()
    var failures = 0
    func report(_ ok: Bool, _ msg: String) {
        Out.line("  \(ok ? "ok  " : "FAIL") \(msg)")
        if !ok { failures += 1 }
    }

    Out.line("Session counts: find vs SessionIndex")
    for scan in lib.instances {
        let root = scan.instance.sessionsRoot.path
        guard FileManager.default.fileExists(atPath: root) else {
            Out.line("\(scan.instance.name): no claude-code-sessions folder, index has \(scan.entries.count)")
            report(scan.entries.isEmpty, "\(scan.instance.name): 0 on disk, \(scan.entries.count) indexed")
            continue
        }
        let found = (shell("/usr/bin/find", [root, "-type", "f", "-name", "local_*.json"]) ?? "")
            .split(separator: "\n").map(String.init)
        var perDir: [String: Int] = [:]
        for f in found { perDir[(f as NSString).deletingLastPathComponent, default: 0] += 1 }
        Out.line("\(scan.instance.name): find \(found.count), index \(scan.entries.count), unreadable \(scan.unreadableCount)")
        report(found.count == scan.entries.count, "\(scan.instance.name): total")
        for o in scan.orgs {
            let n = perDir[o.url.path] ?? 0
            if n != o.entries.count { report(false, "\(scan.instance.name) \(AccountLabels.shortID(o.accountID))/\(AccountLabels.shortID(o.orgID)): find \(n), index \(o.entries.count)") }
        }
        let known = Set(scan.orgs.map(\.url.path))
        for (dir, n) in perDir where !known.contains(dir) { report(false, "\(scan.instance.name): \(n) files in unindexed folder \(dir)") }
    }

    Out.line("Running chips vs ~/.claude/sessions")
    // Independent route: parse the *.json files again here and test liveness with ps instead of kill(2).
    var expected: [String: String] = [:] // local id -> idle/busy
    let dir = env.claudeSessionsDir
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var liveProcs = 0
    for f in files where f.pathExtension == "json" {
        guard let data = try? Data(contentsOf: f),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (d["pid"] as? NSNumber)?.intValue else { continue }
        guard (shell("/bin/ps", ["-p", String(pid), "-o", "pid="]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == String(pid) else { continue }
        liveProcs += 1
        if let host = d["hostSessionId"] as? String { 
            let status = (d["status"] as? String) ?? "idle"
            if expected[host] != "busy" { expected[host] = status }
        }
    }
    let ids = Set(lib.allEntries.map(\.id))
    var chipRunning: [String: String] = [:]
    for e in lib.allEntries {
        let chips = lib.chips(for: e)
        if chips.contains(.busy) { chipRunning[e.id] = "busy" } else if chips.contains(.running) { chipRunning[e.id] = "idle" }
    }
    let expectedWithEntry = expected.filter { ids.contains($0.key) }
    Out.line("live processes \(liveProcs), with a session in some copy \(expectedWithEntry.count), chips shown \(chipRunning.count) (busy \(chipRunning.values.filter { $0 == "busy" }.count))")
    report(expectedWithEntry.count == chipRunning.count, "running chip count")
    for (id, st) in expectedWithEntry where chipRunning[id] != st {
        report(false, "\(id): sessions folder says \(st), chip says \(chipRunning[id] ?? "none")")
    }
    for id in chipRunning.keys where expectedWithEntry[id] == nil { report(false, "\(id): chip without a live process") }
    let orphans = expected.keys.filter { !ids.contains($0) }.count
    if orphans > 0 { Out.line("note: \(orphans) live host session(s) have no entry in any copy (not a mismatch)") }

    Out.line(failures == 0 ? "PASS" : "FAIL (\(failures) mismatch\(failures == 1 ? "" : "es"))")
    return failures == 0 ? 0 : 1
}

// MARK: move, history, undo

func glyph(_ s: CheckStatus) -> String {
    switch s { case .pass: "ok   "; case .warn: "warn "; case .block: "BLOCK" }
}

func printRows(_ rows: [AggregatedRow]) {
    for r in rows {
        Out.line("  \(glyph(r.status)) \(r.title)\(r.detail.map { "  (\($0))" } ?? "")")
        if r.status != .pass, r.total > 1 { for t in r.affected { Out.line("          - \(t)") } }
    }
}

func makeEngine(env: SMEnvironment) -> MoveEngine {
    let engine = MoveEngine(env: env, labels: SettingsStore(env: env).load().labels)
    if let step = ProcessInfo.processInfo.environment["SM_TEST_CRASH_AT"], !step.isEmpty {
        engine.crashHook = { s in
            guard s == step else { return false }
            Out.err("SM_TEST_CRASH_AT=\(step): exiting now, as if killed.")
            exit(9)
        }
    }
    return engine
}

func progressPrinter() -> @Sendable (MoveStep, MoveStepState) -> Void {
    { step, state in if state == .done { Out.line("  done  \(step.title)") } }
}

func printOutcome(_ outcome: MoveOutcome) {
    if !outcome.quit.isEmpty { Out.line("Quit and reopened: \(outcome.quit.map(\.name).joined(separator: ", "))") }
    for r in outcome.reopenFailed { Out.err("Couldn't reopen \(r.name). The work itself is done. Open \(r.name) yourself.") }
}

func reportFailure(_ error: Error) {
    Out.err(error.localizedDescription)
    if let e = error as? MoveError {
        Out.err("log: \(e.log)")
        if case .blocked(let rows) = e { for r in rows { Out.err("  - \(r.title)\(r.detail.map { " (\($0))" } ?? "")") } }
    }
}

func runMove(_ args: [String], env: SMEnvironment) -> Int32 {
    var ids: [String] = []
    var to: String?, from: String?
    var dry = false, quit = false, noReopen = false, replace = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--to": i += 1; to = i < args.count ? args[i] : nil
        case "--from": i += 1; from = i < args.count ? args[i] : nil
        case "--dry-run": dry = true
        case "--quit": quit = true
        case "--no-reopen": noReopen = true
        case "--replace": replace = true
        default: ids.append(args[i])
        }
        i += 1
    }
    guard !ids.isEmpty, let to else {
        Out.err("usage: smctl move <local_id>... --to <slug>[/<account>[/<org>]] [--from <slug>] [--dry-run] [--replace] [--quit [--no-reopen]]")
        return 2
    }
    if noReopen && !quit { Out.err("--no-reopen only makes sense with --quit."); return 2 }
    let engine = makeEngine(env: env)
    let lib = LibraryScanner(env: env).scan()
    let dest: MoveDestination
    do { dest = try MoveDestination.parse(to, in: lib, labels: engine.labels) }
    catch { Out.err(error.localizedDescription); return 2 }
    var fromID: String?
    if let from {
        do { fromID = try MoveDestination.parse(from, in: lib, labels: engine.labels).instanceID }
        catch { Out.err(error.localizedDescription); return 2 }
    }
    var entries: [SessionEntry] = []
    for raw in ids {
        let id = raw.hasPrefix("local_") ? raw : "local_\(raw)"
        let hits = lib.allEntries.filter { $0.id == id && (fromID == nil || $0.instanceID == fromID) }
        if hits.isEmpty { Out.err("\(id) isn't in any Claude copy\(fromID == nil ? "" : " of that instance")."); return 2 }
        if hits.count > 1 { Out.err("\(id) is in \(hits.map { lib.instance($0.instanceID)?.name ?? "?" }.joined(separator: " and ")). Pass --from <slug>."); return 2 }
        entries.append(hits[0])
    }
    let plan = engine.preflight(sessions: entries, to: dest, allowQuit: quit, replace: replace)
    guard plan.destinationInstance != nil else { Out.err("Destination not found."); return 2 }
    Out.line("Move \(plan.items.count == 1 ? "\"\(plan.items[0].entry.displayTitle)\"" : "\(plan.items.count) sessions")")
    if plan.items.count == 1 {
        let s = plan.items[0]
        Out.line("From \(engine.phrase(s.source.name, account: s.entry.accountID))  ->  To \(plan.destinationPhrase)")
    } else { Out.line("To \(plan.destinationPhrase)") }
    printRows(plan.rows)
    Out.line("  info  History comes along. Conversations live in ~/.claude/projects, which every instance reads. This move doesn't touch them.")
    if plan.items.count > 1 {
        for s in plan.blocked { Out.line("  skip  \"\(s.entry.displayTitle)\": \(s.blocks.first?.title ?? "blocked")") }
    }
    guard plan.canMove else { Out.line("Blocked. Nothing changed."); return 2 }
    if dry {
        for s in plan.movable { Out.line("dry run: \(s.entry.fileURL.path) -> \(s.dstURL?.path ?? "?")") }
        return 0
    }
    do {
        let rec: MoveRecord
        if quit {
            let outcome = try engine.performWithQuit(plan, reopen: !noReopen, progress: progressPrinter())
            printOutcome(outcome)
            rec = outcome.record
        } else {
            rec = try engine.perform(plan, progress: progressPrinter())
        }
        Out.line("Moved \(rec.items.count) session\(rec.items.count == 1 ? "" : "s") to \(plan.destinationPhrase).")
        Out.line("move id \(rec.id)")
        return 0
    } catch {
        reportFailure(error)
        return 1
    }
}

func runHistory(env: SMEnvironment) {
    let engine = makeEngine(env: env)
    let h = engine.history()
    if h.isEmpty { Out.line("No moves yet."); return }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    for e in h {
        let r = e.record
        let result: String
        switch r.state {
        case .done: result = "Done"
        case .undone: result = r.isCopy ? "Archived" : "Restored"
        case .rolledBack: result = "Rolled back"
        case .started: result = "Needs attention"
        }
        let from = r.fromNames.joined(separator: ", ")
        let kind = r.isCopy ? "Copy" : "Move"
        let step = r.state == .started ? "  (stopped after: \(r.step ?? "start"))" : ""
        Out.line("\(r.id)  \(f.string(from: r.createdAt))  \(kind)  \(r.title)  \(from) -> \(engine.phrase(r.to.name, account: r.toAccountID))  \(result)\(step)")
    }
    let bytes = h.reduce(Int64(0)) { $0 + $1.backupBytes }
    Out.line("\(h.count) moves · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of backups")
}

func runUndo(_ args: [String], env: SMEnvironment) -> Int32 {
    let quit = args.contains("--quit"), noReopen = args.contains("--no-reopen")
    guard let id = args.first(where: { !$0.hasPrefix("--") }) else { Out.err("usage: smctl undo <move id> [--quit [--no-reopen]]"); return 2 }
    let engine = makeEngine(env: env)
    guard let rec = engine.record(id: id) else { Out.err(MoveError.noRecord(id).localizedDescription); return 2 }
    let plan = engine.restorePlan(for: rec, allowQuit: quit)
    Out.line("\(rec.isCopy ? "Archive the copy of" : "Restore") \(rec.title)")
    for r in plan.rows { Out.line("  \(glyph(r.status)) \(r.title)\(r.detail.map { "  (\($0))" } ?? "")") }
    if plan.isBlocked { Out.line("Blocked. Nothing changed."); return 2 }
    do {
        let r: MoveRecord
        if quit {
            let outcome = try engine.undoWithQuit(rec, reopen: !noReopen, progress: progressPrinter())
            printOutcome(outcome)
            r = outcome.record
        } else { r = try engine.undo(rec) }
        if rec.isCopy {
            var settings = SettingsStore(env: env).load()
            settings.removeCopyMarks(moveID: rec.id)
            try? SettingsStore(env: env).save(settings)
            Out.line("Archived the copy in \(rec.to.name). It isn't deleted.")
        } else {
            Out.line("Restored \(r.items.count) session\(r.items.count == 1 ? "" : "s").")
        }
        Out.line("move id \(r.id)")
        return 0
    } catch {
        reportFailure(error)
        return 1
    }
}

// MARK: formatguard

/// Per copy: version, verified or not, and the entry keys it writes that the verified fingerprint doesn't have.
/// Reads key names only; no value is printed. Exit 0 always: this is a report, not a gate.
func runFormatGuard(env: SMEnvironment) {
    let lib = LibraryScanner(env: env).scan()
    let guardian = FormatGuard.standard
    Out.line("Verified versions: \(guardian.verified.sorted().joined(separator: ", "))")
    for scan in lib.instances {
        let r = guardian.report(for: scan)
        let v = r.version ?? "unknown version"
        Out.line("\(r.name)  \(v)  \(r.verified ? "verified" : "NOT verified (moves use Open a Copy)")  \(r.entriesRead) entries read\(r.unreadable > 0 ? ", \(r.unreadable) unreadable" : "")")
        if !r.hasFingerprint {
            Out.line("  no fingerprint recorded: unknown keys can't be told apart")
        } else if r.unknownKeys.isEmpty {
            Out.line("  no top-level keys beyond the \(r.comparedWith ?? "") fingerprint")
        } else {
            Out.line("  \(r.unknownKeys.count) top-level key\(r.unknownKeys.count == 1 ? "" : "s") not in the \(r.comparedWith ?? "") fingerprint")
            for (k, n) in r.unknownKeys.sorted(by: { $0.key < $1.key }) { Out.line("    \(k)  (\(n) entr\(n == 1 ? "y" : "ies"))") }
        }
    }
}

// MARK: copy

@MainActor
func runCopy(_ args: [String], env: SMEnvironment) async -> Int32 {
    var ids: [String] = []
    var to: String?, from: String?
    var dry = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--to": i += 1; to = i < args.count ? args[i] : nil
        case "--from": i += 1; from = i < args.count ? args[i] : nil
        case "--dry-run": dry = true
        default: ids.append(args[i])
        }
        i += 1
    }
    guard ids.count == 1, let to else {
        Out.err("usage: smctl copy <local_id> --to <slug>[/<account>] [--from <slug>] [--dry-run]")
        return 2
    }
    let engine = makeEngine(env: env)
    let lib = LibraryScanner(env: env).scan()
    let dest: MoveDestination
    do { dest = try MoveDestination.parse(to, in: lib, labels: engine.labels) }
    catch { Out.err(error.localizedDescription); return 2 }
    var fromID: String?
    if let from {
        do { fromID = try MoveDestination.parse(from, in: lib, labels: engine.labels).instanceID }
        catch { Out.err(error.localizedDescription); return 2 }
    }
    let id = ids[0].hasPrefix("local_") ? ids[0] : "local_\(ids[0])"
    let hits = lib.allEntries.filter { $0.id == id && (fromID == nil || $0.instanceID == fromID) }
    if hits.isEmpty { Out.err("\(id) isn't in any Claude copy\(fromID == nil ? "" : " of that instance")."); return 2 }
    if hits.count > 1 { Out.err("\(id) is in \(hits.map { lib.instance($0.instanceID)?.name ?? "?" }.joined(separator: " and ")). Pass --from <slug>."); return 2 }
    let plan = engine.copyPlan(entry: hits[0], to: dest, library: lib)
    Out.line("Open a copy of \"\(plan.entry.displayTitle)\" in \(plan.destinationPhrase)")
    for r in plan.rows { Out.line("  \(glyph(r.status)) \(r.title)\(r.detail.map { "  (\($0))" } ?? "")") }
    Out.line("  info  The original stays in \(plan.source.name). Don't run both at once.")
    guard plan.canCopy else { Out.line("Blocked. Nothing changed."); return 2 }
    if dry {
        Out.line("dry run: claude://resume?session=\(plan.entry.summary?.cliSessionId ?? "?") -> \(plan.destination?.appURL.path ?? "?")")
        return 0
    }
    do {
        let rec = try await engine.performCopy(plan)
        if let mark = engine.copyMark(for: rec) {
            var settings = SettingsStore(env: env).load()
            settings.addCopyMark(mark)
            try? SettingsStore(env: env).save(settings)
        }
        Out.line("Opened a copy in \(plan.destinationPhrase).")
        Out.line("move id \(rec.id)")
        return 0
    } catch {
        reportFailure(error)
        return 1
    }
}

// MARK: recover

func runRecover(_ args: [String], env: SMEnvironment) -> Int32 {
    let finish = args.contains("--finish"), roll = args.contains("--roll-back"), noReopen = args.contains("--no-reopen")
    let engine = makeEngine(env: env)
    guard let id = args.first(where: { !$0.hasPrefix("--") }) else {
        let found = engine.recoverableMoves()
        if found.isEmpty { Out.line("No interrupted moves."); return 0 }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        for r in found {
            let can = engine.canFinish(r) ? "can finish" : "roll back only"
            Out.line("\(r.id)  \(f.string(from: r.createdAt))  \(r.title)  \(r.fromNames.joined(separator: ", ")) -> \(r.to.name)  stopped after: \(r.step ?? "start")  (\(can))")
        }
        Out.line("smctl recover <move id> --finish | --roll-back")
        return 0
    }
    guard finish != roll else { Out.err("usage: smctl recover <move id> --finish | --roll-back [--no-reopen]"); return 2 }
    guard let rec = engine.record(id: id) else { Out.err(MoveError.noRecord(id).localizedDescription); return 2 }
    guard rec.state == .started else { Out.err("Move \(id) isn't unfinished (\(rec.state.rawValue))."); return 2 }
    let plan = finish ? engine.finishPlan(for: rec, allowQuit: true) : engine.restorePlan(for: rec, allowQuit: true)
    Out.line("\(finish ? "Finish" : "Roll back") \(rec.title)\(rec.step.map { "  (stopped after: \($0))" } ?? "")")
    for r in plan.rows { Out.line("  \(glyph(r.status)) \(r.title)\(r.detail.map { "  (\($0))" } ?? "")") }
    if plan.isBlocked { Out.line("Blocked. Nothing changed."); return 2 }
    do {
        let outcome = finish ? try engine.finish(rec, reopen: !noReopen, progress: progressPrinter())
                             : try engine.rollBack(rec, reopen: !noReopen, progress: progressPrinter())
        printOutcome(outcome)
        Out.line(finish ? "Finished the move." : "Rolled back. Everything is as it was before the move.")
        Out.line("move id \(outcome.record.id)")
        return 0
    } catch {
        reportFailure(error)
        return 1
    }
}

// MARK: main

let args = Array(CommandLine.arguments.dropFirst())
let env = SMEnvironment.fromProcess()
switch args.first {
case "list": runList(Array(args.dropFirst()), env: env)
case "check": exit(runCheck(env: env))
case "move": exit(runMove(Array(args.dropFirst()), env: env))
case "history": runHistory(env: env)
case "undo": exit(runUndo(Array(args.dropFirst()), env: env))
case "copy": exit(await runCopy(Array(args.dropFirst()), env: env))
case "formatguard": runFormatGuard(env: env)
case "recover": exit(runRecover(Array(args.dropFirst()), env: env))
default:
    Out.err("""
    usage: smctl list [--json] [--counts] | smctl check | smctl formatguard
           smctl move <local_id>... --to <slug>[/<account>[/<org>]] [--from <slug>] [--dry-run] [--replace] [--quit [--no-reopen]]
           smctl copy <local_id> --to <slug>[/<account>] [--from <slug>] [--dry-run]
           smctl recover [<move id> --finish | --roll-back] [--no-reopen]
           smctl history | smctl undo <move id> [--quit [--no-reopen]]
    (SM_HOME overrides the home folder; SM_ALLOW lists the copies moves may write to)
    """)
    exit(args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 2)
}
