import Foundation
#if canImport(AppKit)
import AppKit
#endif

public protocol RunningAppsProviding: Sendable {
    func isRunning(bundleID: String) -> Bool
}

/// Running copies, by bundle id (never by process name: the launcher and `<Name>.real` differ).
public struct WorkspaceRunningApps: RunningAppsProviding {
    public init() {}
    public func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }
}

public struct LiveSession: Sendable, Hashable {
    public enum Status: Sendable, Hashable { case idle, busy, other(String) }
    public var pid: Int32
    public var status: Status
    public var hostSessionId: String?
    public var cliSessionId: String?
    public var isBusy: Bool { status == .busy }
}

/// Live Claude Code processes from `~/.claude/sessions/<pid>.json`.
/// Only `*.json` files are read. The `<pid>.<hash>.key` files next to them are never opened.
public enum LiveStateReader {
    public static let defaultIsAlive: @Sendable (Int32) -> Bool = { pid in
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func readSessions(in dir: URL, isAlive: @Sendable (Int32) -> Bool = defaultIsAlive) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNum = d["pid"] as? NSNumber else { continue }
            let pid = pidNum.int32Value
            guard isAlive(pid) else { continue }
            let status: LiveSession.Status
            switch (d["status"] as? String) ?? "" {
            case "busy": status = .busy
            case "idle": status = .idle
            case let other: status = .other(other)
            }
            out.append(LiveSession(pid: pid, status: status,
                                   hostSessionId: d["hostSessionId"] as? String,
                                   cliSessionId: d["sessionId"] as? String))
        }
        return out
    }
}
