import Foundation

/// What is known about one verified Claude app version.
public struct VerifiedVersion: Codable, Equatable, Sendable {
    public var verifiedOn: String?
    /// Top-level keys seen in that version's `local_*.json` entries. Names only, never values.
    public var topLevelKeys: [String]
    public init(verifiedOn: String? = nil, topLevelKeys: [String] = []) { self.verifiedOn = verifiedOn; self.topLevelKeys = topLevelKeys }
}

struct VerifiedVersionsFile: Codable {
    var schema: Int?
    var versions: [String: VerifiedVersion]
}

/// What `smctl formatguard` and the app show for one copy.
public struct FormatReport: Sendable, Equatable {
    public var name: String
    public var version: String?
    public var verified: Bool
    /// Entries whose keys were read.
    public var entriesRead: Int
    /// Entries that could not be parsed as a JSON object.
    public var unreadable: Int
    /// Keys not in the version's fingerprint, with how many entries carry each. Empty when the version has no fingerprint.
    public var unknownKeys: [String: Int]
    /// The version has a recorded set of keys to compare against.
    public var hasFingerprint: Bool
    /// The verified version whose keys were used. An unverified copy is compared with the newest verified one.
    public var comparedWith: String?
}

/// Claude app versions whose on-disk formats a full move has been verified against, with the entry keys each
/// was seen to write. A copy on any other version gets a block until someone re-verifies it (see docs/phase0-findings.md).
/// The list is data: `Resources/verified-versions.json`.
public struct FormatGuard: Sendable {
    /// Used only when the bundled file is missing, so a broken bundle never unlocks moves for unknown versions.
    static let fallback: [String: VerifiedVersion] = ["4.29.0": VerifiedVersion()]
    public static let resourceName = "verified-versions"

    public static let bundled: [String: VerifiedVersion] = loadBundled() ?? fallback
    public static var verifiedVersions: Set<String> { Set(bundled.keys) }
    public static let standard = FormatGuard()

    public var versions: [String: VerifiedVersion]
    public var verified: Set<String> { Set(versions.keys) }

    public init(versions: [String: VerifiedVersion] = FormatGuard.bundled) { self.versions = versions }
    public init(verified: Set<String>) { versions = Dictionary(uniqueKeysWithValues: verified.map { ($0, VerifiedVersion()) }) }

    public func isVerified(_ version: String?) -> Bool {
        guard let v = version?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return false }
        return versions[v] != nil
    }

    /// "Alpha 4.30.1 isn't verified yet." or nil when the copy is fine.
    public func blockMessage(for instance: Instance) -> String? {
        if isVerified(instance.version) { return nil }
        return "\(Self.unverifiedPhrase(instance))."
    }

    /// "Alpha 4.30.1 isn't verified yet"; the banner and the Move sheet share it.
    public static func unverifiedPhrase(_ instance: Instance) -> String {
        let v = instance.version.flatMap { $0.isEmpty ? nil : $0 }
        return "\(instance.name) \(v ?? "(unknown version)") isn't verified yet"
    }

    // MARK: Fingerprint

    public func fingerprint(for version: String?) -> Set<String>? {
        guard let v = version?.trimmingCharacters(in: .whitespaces), let e = versions[v], !e.topLevelKeys.isEmpty else { return nil }
        return Set(e.topLevelKeys)
    }

    /// The fingerprint to compare a copy's entries with: its own version's, else the newest verified version's.
    public func reference(for version: String?) -> (version: String, keys: Set<String>)? {
        if let v = version?.trimmingCharacters(in: .whitespaces), let k = fingerprint(for: v) { return (v, k) }
        let newest = versions.filter { !$0.value.topLevelKeys.isEmpty }.keys
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
        guard let n = newest else { return nil }
        return (n, Set(versions[n]!.topLevelKeys))
    }

    /// Keys in `keys` that the reference fingerprint doesn't have. Empty when there is no fingerprint at all.
    public func unknownKeys(_ keys: Set<String>, version: String?) -> Set<String> {
        guard let ref = reference(for: version) else { return [] }
        return keys.subtracting(ref.keys)
    }

    /// Reads the top-level key names of every entry in one copy and compares them with its version's fingerprint.
    /// Only key names are kept; values are dropped as each file is parsed.
    public func report(for scan: InstanceScan) -> FormatReport {
        var counts: [String: Int] = [:]
        var read = 0, bad = 0
        for e in scan.entries {
            guard let data = try? Data(contentsOf: e.fileURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { bad += 1; continue }
            read += 1
            for k in unknownKeys(Set(obj.keys), version: scan.instance.version) { counts[k, default: 0] += 1 }
        }
        return FormatReport(name: scan.instance.name, version: scan.instance.version, verified: isVerified(scan.instance.version),
                            entriesRead: read, unreadable: bad, unknownKeys: counts,
                            hasFingerprint: reference(for: scan.instance.version) != nil,
                            comparedWith: reference(for: scan.instance.version)?.version)
    }

    // MARK: Bundled data

    /// The app bundle's own `Contents/Resources` first (build-app.sh puts the file there), then the SwiftPM
    /// resource bundle (swift run, swift test).
    static func loadBundled() -> [String: VerifiedVersion]? {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: resourceName, withExtension: "json") { urls.append(u) }
        if let b = moduleBundle {
            if let u = b.url(forResource: resourceName, withExtension: "json") { urls.append(u) }
            if let u = b.url(forResource: resourceName, withExtension: "json", subdirectory: "Resources") { urls.append(u) }
        }
        for u in urls {
            if let data = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(VerifiedVersionsFile.self, from: data), !f.versions.isEmpty {
                return f.versions
            }
        }
        return nil
    }

    /// `Bundle.module` traps when the resource bundle isn't beside the executable, so look for it by hand.
    private static var moduleBundle: Bundle? {
        let name = "SessionMover_SessionMoverKit.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: BundleToken.self).resourceURL,
                          Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()]
        for c in candidates.compactMap({ $0 }) {
            if let b = Bundle(url: c.appendingPathComponent(name)) { return b }
        }
        return nil
    }
    private final class BundleToken {}
}
