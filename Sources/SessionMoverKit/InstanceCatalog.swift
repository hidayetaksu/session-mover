import Foundation

/// One copy of the Claude desktop app: the original, a Claude Profiles clone, or a stray bundle found in /Applications.
public struct Instance: Identifiable, Hashable, Sendable {
    public enum Origin: String, Sendable { case original, profile, discovered }

    public var id: String { bundleID }
    public var name: String
    public var slug: String?
    public var bundleID: String
    public var appURL: URL
    public var dataURL: URL
    public var accentHex: String
    public var iconName: String
    public var version: String?
    public var kind: String?
    public var origin: Origin
    public var appInstalled: Bool
    public var dataFolderExists: Bool

    public var isOriginal: Bool { origin == .original }
    public var sessionsRoot: URL { dataURL.appendingPathComponent("claude-code-sessions", isDirectory: true) }
}

public struct InstanceCatalog: Sendable {
    public static let defaultAccent = "#D97757"
    public static let defaultIcon = "sparkle"

    public let env: SMEnvironment
    public init(env: SMEnvironment) { self.env = env }

    private struct ProfilesFile: Decodable { var profiles: [Profile]? }
    private struct Profile: Decodable {
        var name: String?
        var slug: String?
        var accentColorHex: String?
        var iconName: String?
        var bundleVersion: String?
        var kind: String?
    }

    /// Original copy first, then Claude Profiles in file order, then any other `com.anthropic.claudefordesktop*` bundle.
    public func load() -> [Instance] {
        let fm = FileManager.default
        var result: [Instance] = []
        var seen = Set<String>()

        let originalApp = env.applicationsDir.appendingPathComponent("Claude.app", isDirectory: true)
        let originalInstalled = fm.fileExists(atPath: originalApp.path)
        let originalData = fm.fileExists(atPath: env.originalDataDir.path)
        if originalInstalled || originalData {
            result.append(Instance(
                name: "Claude", slug: nil, bundleID: Bundles.original, appURL: originalApp, dataURL: env.originalDataDir,
                accentHex: Self.defaultAccent, iconName: Self.defaultIcon,
                version: Self.bundleInfo(originalApp)?.version, kind: "claude", origin: .original,
                appInstalled: originalInstalled, dataFolderExists: originalData))
            seen.insert(Bundles.original)
        }

        if let data = try? Data(contentsOf: env.profilesJSON),
           let file = try? JSONDecoder().decode(ProfilesFile.self, from: data) {
            for p in file.profiles ?? [] {
                guard let slug = p.slug, !slug.isEmpty, !slug.contains("/") else { continue }
                let bundle = Bundles.profile(slug: slug)
                guard seen.insert(bundle).inserted else { continue }
                let app = env.applicationsDir.appendingPathComponent("Claude-\(slug).app", isDirectory: true)
                let dataDir = env.profileDataDir(slug: slug)
                result.append(Instance(
                    name: p.name ?? slug, slug: slug, bundleID: bundle, appURL: app, dataURL: dataDir,
                    accentHex: p.accentColorHex ?? Self.defaultAccent, iconName: p.iconName ?? Self.defaultIcon,
                    version: Self.bundleInfo(app)?.version ?? p.bundleVersion, kind: p.kind, origin: .profile,
                    appInstalled: fm.fileExists(atPath: app.path),
                    dataFolderExists: fm.fileExists(atPath: dataDir.path)))
            }
        }

        let apps = (try? fm.contentsOfDirectory(at: env.applicationsDir, includingPropertiesForKeys: nil)) ?? []
        for app in apps.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where app.pathExtension == "app" {
            guard let info = Self.bundleInfo(app), let bid = info.bundleID,
                  bid.hasPrefix(Bundles.original), !seen.contains(bid) else { continue }
            seen.insert(bid)
            let slug = bid.hasPrefix(Bundles.original + "-") ? String(bid.dropFirst(Bundles.original.count + 1)) : nil
            let dataDir = slug.map(env.profileDataDir(slug:)) ?? env.originalDataDir
            result.append(Instance(
                name: info.name ?? app.deletingPathExtension().lastPathComponent, slug: slug, bundleID: bid,
                appURL: app, dataURL: dataDir, accentHex: "#8E8E93", iconName: "app.dashed",
                version: info.version, kind: nil, origin: .discovered, appInstalled: true,
                dataFolderExists: fm.fileExists(atPath: dataDir.path)))
        }
        return result
    }

    struct BundleInfo { var bundleID: String?; var version: String?; var name: String? }

    static func bundleInfo(_ app: URL) -> BundleInfo? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let d = obj as? [String: Any] else { return nil }
        return BundleInfo(bundleID: d["CFBundleIdentifier"] as? String,
                          version: d["CFBundleShortVersionString"] as? String,
                          name: (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String))
    }
}

/// Reads the signed-in account from a copy's `config.json`.
///
/// That file also holds OAuth token caches, so it is never decoded into a model, logged, or kept: the
/// bytes are scanned for the one key and everything else is dropped when the function returns.
public enum SignedInAccount {
    private static let key = Array("\"lastKnownAccountUuid\"".utf8)

    public static func read(dataDir: URL) -> String? {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("config.json"), options: .mappedIfSafe) else { return nil }
        return extract(from: data)
    }

    static func extract(from data: Data) -> String? {
        guard let r = data.range(of: Data(key)) else { return nil }
        var i = r.upperBound
        func skipSpace() { while i < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[i]) { i += 1 } }
        skipSpace()
        guard i < data.endIndex, data[i] == UInt8(ascii: ":") else { return nil }
        i += 1; skipSpace()
        guard i < data.endIndex, data[i] == UInt8(ascii: "\"") else { return nil }
        i += 1
        var bytes: [UInt8] = []
        while i < data.endIndex, data[i] != UInt8(ascii: "\""), bytes.count <= 36 { bytes.append(data[i]); i += 1 }
        guard bytes.count == 36, let s = String(bytes: bytes, encoding: .ascii), UUID(uuidString: s) != nil else { return nil }
        return s.lowercased()
    }
}
