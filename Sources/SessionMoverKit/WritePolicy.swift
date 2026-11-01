import Foundation

/// Which copies the move engine may write into or out of. Everything else is read-only.
///
/// Source of truth, first match wins: env `SM_ALLOW` (comma list of slugs, or `all`), then the
/// `writableInstances` key of settings.json, then the default `["test1", "test2"]`.
/// The original Claude.app is the slug `default`.
public struct WritePolicy: Sendable, Equatable {
    public static let defaultSlugs = ["test1", "test2"]

    public enum Allowed: Sendable, Equatable { case all, slugs(Set<String>) }
    public var allowed: Allowed

    public init(allowed: Allowed) { self.allowed = allowed }
    public static let all = WritePolicy(allowed: .all)

    public static func parse(_ list: String) -> Allowed {
        let items = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return items.contains("all") ? .all : .slugs(Set(items))
    }

    public static func current(env: SMEnvironment, processEnv: [String: String] = ProcessInfo.processInfo.environment) -> WritePolicy {
        if let s = processEnv["SM_ALLOW"] { return WritePolicy(allowed: parse(s)) }
        if let list = SettingsStore(env: env).load().writableInstances {
            return WritePolicy(allowed: list.contains { $0.lowercased() == "all" } ? .all : .slugs(Set(list.map { $0.lowercased() })))
        }
        return WritePolicy(allowed: .slugs(Set(defaultSlugs)))
    }

    /// True when `SM_ALLOW` is set: it wins over the Settings list.
    public static func isOverriddenByEnvironment(_ processEnv: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        processEnv["SM_ALLOW"] != nil
    }

    /// The `writableInstances` value that makes exactly `slugs` writable.
    public static func settingsList(enabling slugs: Set<String>) -> [String] { slugs.map { $0.lowercased() }.sorted() }

    public func allows(slug: String) -> Bool {
        switch allowed {
        case .all: return true
        case .slugs(let s): return s.contains(slug.lowercased())
        }
    }
    public func allows(_ instance: Instance) -> Bool { allows(slug: instance.writeSlug) }

    public var summary: String {
        switch allowed {
        case .all: return "all"
        case .slugs(let s): return s.sorted().joined(separator: ", ")
        }
    }
}

extension Instance {
    /// The slug the write allowlist uses: the Claude Profiles slug, or `default` for the original Claude.app.
    public var writeSlug: String { slug ?? "default" }
}
