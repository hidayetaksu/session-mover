import Foundation

/// Where everything lives. Every home path derives from `home`, so tests and fixtures can point the
/// whole Kit at a temp tree with `SM_HOME`.
public struct SMEnvironment: Sendable {
    public var home: URL
    public var applicationsDir: URL

    public init(home: URL, applicationsDir: URL? = nil) {
        self.home = home
        self.applicationsDir = applicationsDir ?? home.appendingPathComponent("Applications", isDirectory: true)
    }

    /// `SM_HOME` replaces the home folder (and `<SM_HOME>/Applications` replaces /Applications);
    /// `SM_APPLICATIONS` overrides the applications folder alone.
    public static func fromProcess(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SMEnvironment {
        let apps = env["SM_APPLICATIONS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let h = env["SM_HOME"], !h.isEmpty {
            return SMEnvironment(home: URL(fileURLWithPath: h, isDirectory: true), applicationsDir: apps)
        }
        return SMEnvironment(home: FileManager.default.homeDirectoryForCurrentUser,
                             applicationsDir: apps ?? URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    public var applicationSupport: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    public var profilesJSON: URL { applicationSupport.appendingPathComponent("ClaudeProfileManager/profiles.json") }
    public var originalDataDir: URL { applicationSupport.appendingPathComponent("Claude", isDirectory: true) }
    public func profileDataDir(slug: String) -> URL {
        home.appendingPathComponent(".claude-profiles/\(slug)/Library/Application Support/Claude", isDirectory: true)
    }
    /// `~/.claude/sessions`: running Claude Code processes. Only `*.json` files are ever read here.
    public var claudeSessionsDir: URL { home.appendingPathComponent(".claude/sessions", isDirectory: true) }
    public var settingsDir: URL { applicationSupport.appendingPathComponent("SessionMover", isDirectory: true) }
    public var settingsFile: URL { settingsDir.appendingPathComponent("settings.json") }
}

public enum Bundles {
    public static let original = "com.anthropic.claudefordesktop"
    public static func profile(slug: String) -> String { "\(original)-\(slug)" }
}
