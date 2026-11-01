import Foundation
import CoreServices

/// Calls `onChange` (on a private queue) after file-system activity under `paths`, coalesced by `latency`.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ai.gosmart.sessionmover.fsevents")
    private let handler: @Sendable () -> Void

    public init?(paths: [URL], latency: TimeInterval = 0.8, onChange: @escaping @Sendable () -> Void) {
        handler = onChange
        let existing = paths.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
