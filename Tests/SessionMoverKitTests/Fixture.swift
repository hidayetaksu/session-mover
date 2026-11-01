import Foundation
@testable import SessionMoverKit

/// A fake home: original copy + two Claude Profiles clones + a stray bundle, two accounts, two orgs,
/// a broken entry, a .tmp file, and a ~/.claude/sessions folder with a .json and a .key.
struct Fixture {
    static let secret = "SECRET-OAUTH-TOKEN-do-not-surface"
    static let acctA = "dcedd406-aafd-4aa2-a511-5a51caba92a1"
    static let acctB = "eb90b3bb-cd87-4b5c-a83a-4f6ea484c48c"
    static let orgX = "2a5d8f8f-ddfc-460a-aee5-4de76b85ff7c"
    static let orgY = "cce874a4-32d6-4294-a91e-3e12425c85c3"
    static let cliBusy = "057d9a7e-d11e-4e5a-af5f-e3c4ff0344f6"

    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var env: SMEnvironment { SMEnvironment(home: home) }
    var existingFolder: String { root.appendingPathComponent("project one").path }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-fixture-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("project one"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // profiles.json
        let profiles = """
        {"profiles":[
         {"name":"Alpha","slug":"alpha","accentColorHex":"#2563EB","iconName":"wrench.fill","bundleVersion":"4.29.0","kind":"claude","extra":{"x":1}},
         {"name":"Beta","slug":"beta","accentColorHex":"#D97706","iconName":"laptopcomputer","bundleVersion":"3.6556.2","kind":"claude"}]}
        """
        try write(profiles, "Library/Application Support/ClaudeProfileManager/profiles.json")

        // apps
        try app("Claude.app", id: "com.anthropic.claudefordesktop", version: "4.29.0")
        try app("Claude-alpha.app", id: "com.anthropic.claudefordesktop-alpha", version: "4.30.1")
        try app("Claude-stray.app", id: "com.anthropic.claudefordesktop-stray", version: "4.0.0", name: "Stray")
        try app("Claude Profiles.app", id: "com.madappgang.claude-profiles", version: "1.4.0")

        // data folders
        let orig = "Library/Application Support/Claude"
        let alpha = ".claude-profiles/alpha/Library/Application Support/Claude"
        try write(#"{"oauth:tokenCache":"\#(Self.secret)","lastKnownAccountUuid":"\#(Self.acctA)","other":{"k":"\#(Self.secret)"}}"#, "\(orig)/config.json")
        try write(#"{"lastKnownAccountUuid": "\#(Self.acctB)", "token":"\#(Self.secret)"}"#, "\(alpha)/config.json")
        // beta has no data folder at all (unreadable instance)

        let dir = existingFolder
        let missing = root.appendingPathComponent("gone/folder").path
        // original: account A, org X: 3 entries (one archived with PRs, one with limit error + missing folder)
        try entry("\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)", "local_aaaa0001", title: "Fix export regex", cli: Self.cliBusy, cwd: dir, last: 1_793_000_000_000, extra: #""branch":"claude/fix-regex","prs":[{"prNumber":843}],"unknownField":{"a":[1,2]}"#)
        try entry("\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)", "local_aaaa0002", title: "Old archived thing", cli: "fe56159c-da13-4589-aa09-bbfd51cb6d4e", cwd: dir, last: 1_792_000_000_000, extra: #""isArchived":true,"isStarred":true"#)
        try entry("\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)", "local_aaaa0003", title: "Hit the limit", cli: "3152f529-8a3f-4550-aca5-1ef8deef4421", cwd: missing, last: 1_791_000_000_000, extra: #""error":"You've hit your session limit · resets 1:30am (America/Los_Angeles)""#)
        try write("{ not json", "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/local_broken.json")
        try write("{}", "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/local_aaaa0009.json.tmp")
        try write("{}", "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/scheduled-tasks.json")
        try write(#"{"v":1,"archived":["local_aaaa0002"]}"#, "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/archived-sessions.idx")
        try fm.createDirectory(at: home.appendingPathComponent("\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgY)"), withIntermediateDirectories: true)
        // alpha: signed in to B; sessions in B/X and A/X (hidden) and A/Y
        try entry("\(alpha)/claude-code-sessions/\(Self.acctB)/\(Self.orgX)", "local_bbbb0001", title: "Alpha visible", cli: "0c61c10e-24fb-4833-ac72-79f056141fcb", cwd: dir, last: 1_793_100_000_000, extra: "")
        try entry("\(alpha)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)", "local_bbbb0002", title: "Alpha hidden one", cli: "51f8cd08-1a91-455b-a3ef-015294feec88", cwd: dir, last: 1_793_200_000_000, extra: "")
        try entry("\(alpha)/claude-code-sessions/\(Self.acctA)/\(Self.orgY)", "local_bbbb0003", title: "Alpha hidden two", cli: "74961a5a-c9dd-41bc-a24e-49be6e41d9b5", cwd: dir, last: 1_793_300_000_000, extra: "")

        // ~/.claude/sessions
        let me = getpid()
        try write(#"{"pid":\#(me),"sessionId":"\#(Self.cliBusy)","hostSessionId":"local_aaaa0001","status":"busy","cwd":"/x"}"#, ".claude/sessions/\(me).json")
        try write(#"{"pid":2147483000,"sessionId":"dead","hostSessionId":"local_aaaa0002","status":"idle"}"#, ".claude/sessions/2147483000.json")
        try write(#"{"pid":\#(me),"hostSessionId":"local_bbbb0001","status":"idle"}"#, ".claude/sessions/\(me).abcdef0123.key")
        try write(#"{"pid":\#(me),"hostSessionId":"local_bbbb0002","status":"idle","sessionId":"cli-b2"}"#, ".claude/sessions/777.json")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func write(_ s: String, _ rel: String) throws {
        let u = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }

    func app(_ name: String, id: String, version: String, name display: String? = nil) throws {
        var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        if let display { plist["CFBundleName"] = display }
        let u = home.appendingPathComponent("Applications/\(name)/Contents/Info.plist")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: u)
    }

    func entry(_ folder: String, _ id: String, title: String, cli: String, cwd: String, last: Int, extra: String) throws {
        let json = #"{"sessionId":"\#(id)","cliSessionId":"\#(cli)","cwd":"\#(cwd)","originCwd":"\#(cwd)","createdAt":\#(last - 1000),"lastActivityAt":\#(last),"title":"\#(title)","model":"claude-opus-5-5","permissionMode":"auto"\#(extra.isEmpty ? "" : "," + extra)}"#
        try write(json, "\(folder)/\(id).json")
    }
}
