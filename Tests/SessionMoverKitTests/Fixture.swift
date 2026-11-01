import Foundation
@testable import SessionMoverKit

/// A fake home: original copy + two Claude Profiles clones + a stray bundle, two accounts, two orgs,
/// a broken entry, a .tmp file, and a ~/.claude/sessions folder with a .json and a .key.
struct Fixture {
    static let secret = "SECRET-OAUTH-TOKEN-do-not-surface"
    static let acctA = "8490f485-d7b1-4b3f-afe6-a0080a129d7e"
    static let acctB = "af49c28e-8815-4aed-abf8-5aeeca43d876"
    static let orgX = "551669f7-f059-43f9-ac49-7be50daf2f34"
    static let orgY = "12327cc6-780c-4bf0-a9cd-d677d5606a13"
    static let cliBusy = "5da54b2c-3145-4fb1-a3db-50f3d4f77dc5"

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
        try entry("\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)", "local_aaaa0002", title: "Old archived thing", cli: "3af5413f-ad2d-4f03-a684-3026a900f317", cwd: dir, last: 1_792_000_000_000, extra: #""isArchived":true,"isStarred":true"#)
        try entry("\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)", "local_aaaa0003", title: "Hit the limit", cli: "56b71fd4-bc47-4a38-afb5-286a8622c7af", cwd: missing, last: 1_791_000_000_000, extra: #""error":"You've hit your session limit · resets 1:30am (America/Los_Angeles)""#)
        try write("{ not json", "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/local_broken.json")
        try write("{}", "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/local_aaaa0009.json.tmp")
        try write("{}", "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/scheduled-tasks.json")
        try write(#"{"v":1,"archived":["local_aaaa0002"]}"#, "\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)/archived-sessions.idx")
        try fm.createDirectory(at: home.appendingPathComponent("\(orig)/claude-code-sessions/\(Self.acctA)/\(Self.orgY)"), withIntermediateDirectories: true)
        // alpha: signed in to B; sessions in B/X and A/X (hidden) and A/Y
        try entry("\(alpha)/claude-code-sessions/\(Self.acctB)/\(Self.orgX)", "local_bbbb0001", title: "Alpha visible", cli: "cf6f18cc-6979-4284-afb9-e407cc72ffad", cwd: dir, last: 1_793_100_000_000, extra: "")
        try entry("\(alpha)/claude-code-sessions/\(Self.acctA)/\(Self.orgX)", "local_bbbb0002", title: "Alpha hidden one", cli: "9696094d-11ea-45fb-ab9f-03627bcaedd4", cwd: dir, last: 1_793_200_000_000, extra: "")
        try entry("\(alpha)/claude-code-sessions/\(Self.acctA)/\(Self.orgY)", "local_bbbb0003", title: "Alpha hidden two", cli: "3ef243f0-b7ae-4f62-ae18-e2bd826da673", cwd: dir, last: 1_793_300_000_000, extra: "")

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
