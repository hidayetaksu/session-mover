import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum LaunchError: LocalizedError, Equatable {
    case noCliSessionId
    case appNotInstalled(String)
    case badAppURL

    public var errorDescription: String? {
        switch self {
        case .noCliSessionId: "This session has no Claude Code id to open."
        case .appNotInstalled(let n): "\(n) isn't installed in Applications."
        case .badAppURL: "Session Mover only opens a copy's app bundle."
        }
    }
}

@MainActor
public protocol WorkspaceOpening {
    func open(_ url: URL, withApplicationAt appURL: URL) async throws
    func reveal(_ url: URL)
}

@MainActor
public struct SystemWorkspace: WorkspaceOpening {
    public init() {}
    public func open(_ url: URL, withApplicationAt appURL: URL) async throws {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg)
    }
    public func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// "Open in its app" and "Reveal in Finder". Neither touches the copy's files.
@MainActor
public struct CopyLauncher {
    let workspace: WorkspaceOpening
    public init(workspace: WorkspaceOpening = SystemWorkspace()) { self.workspace = workspace }

    /// `claude://resume?session=<cliSessionId>`. Nil unless the id looks like a UUID.
    public nonisolated static func resumeURL(cliSessionId: String) -> URL? {
        guard UUID(uuidString: cliSessionId) != nil else { return nil }
        return URL(string: "claude://resume?session=\(cliSessionId.lowercased())")
    }

    /// Aims the deep link at the copy's `.app` by URL; never at the `<Name>.real` binary.
    public func openInItsApp(_ entry: SessionEntry, in instance: Instance) async throws {
        guard let id = entry.summary?.cliSessionId, let url = Self.resumeURL(cliSessionId: id) else { throw LaunchError.noCliSessionId }
        guard instance.appURL.pathExtension == "app" else { throw LaunchError.badAppURL }
        guard instance.appInstalled else { throw LaunchError.appNotInstalled(instance.name) }
        try await workspace.open(url, withApplicationAt: instance.appURL)
    }

    /// Open a copy: the same deep link, aimed at the destination copy's `.app`. Works while apps run.
    public func openCopy(_ entry: SessionEntry, in instance: Instance) async throws {
        try await openInItsApp(entry, in: instance)
    }

    public func reveal(_ entry: SessionEntry) { workspace.reveal(entry.fileURL) }
}
