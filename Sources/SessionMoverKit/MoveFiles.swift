import Foundation
import CryptoKit

/// Small file helpers for the move engine. Everything it writes goes through `writeAtomic`.
enum MoveFiles {
    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(of url: URL) -> String? { (try? Data(contentsOf: url)).map(sha256) }

    /// nil when the file is missing; throws when it exists but isn't a JSON object.
    static func readObject(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "\(url.lastPathComponent) isn't a JSON object.")
        }
        return obj
    }

    static func encode(_ obj: [String: Any], pretty: Bool) throws -> Data {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: obj, options: opts)
    }

    static func mode(of url: URL) -> mode_t? {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber else { return nil }
        return mode_t(n.intValue)
    }

    /// Temp name in the same folder, then fsync, chmod, rename.
    /// The temp name must not start with `local_`: Claude promotes a leftover `local_X.json.tmp` into an entry.
    static func writeAtomic(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".sm-\(UUID().uuidString.lowercased()).tmp")
        do {
            try data.write(to: tmp)
            let h = try FileHandle(forWritingTo: tmp)
            try h.synchronize()
            try h.close()
            guard chmod(tmp.path, mode) == 0 else { throw Failure(message: "chmod failed on \(tmp.lastPathComponent)") }
            guard rename(tmp.path, url.path) == 0 else { throw Failure(message: "rename failed for \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Nested dictionary edit that creates missing levels.
    static func mutate(_ d: inout [String: Any], path: ArraySlice<String>, _ body: (inout [String: Any]) -> Void) {
        guard let k = path.first else { body(&d); return }
        var child = d[k] as? [String: Any] ?? [:]
        mutate(&child, path: path.dropFirst(), body)
        d[k] = child
    }

    static func lookup(_ d: [String: Any], _ path: [String]) -> Any? {
        var cur: Any? = d
        for k in path { cur = (cur as? [String: Any])?[k] }
        return cur
    }

    /// Existing ancestors are kept; returns the folders created (outermost first).
    static func makeDirs(_ dir: URL, mode: Int = 0o700) throws -> [URL] {
        let fm = FileManager.default
        var missing: [URL] = []
        var cur = dir
        while !fm.fileExists(atPath: cur.path), cur.pathComponents.count > 1 { missing.append(cur); cur.deleteLastPathComponent() }
        for d in missing.reversed() {
            try fm.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
        }
        return missing.reversed()
    }
}
