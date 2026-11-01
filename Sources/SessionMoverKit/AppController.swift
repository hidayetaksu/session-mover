import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Why a copy could not be quit or reopened.
public enum AppControlError: LocalizedError, Equatable {
    case notAllowed(String)
    case didntQuit(String)
    case cantReopen(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let n): "Moving into or out of \(n) is turned off."
        case .didntQuit(let n): "\(n) didn't quit."
        case .cantReopen(let n): "Couldn't reopen \(n)."
        case .cancelled: "Stopped. Nothing changed."
        }
    }
}

/// A thread-safe stop flag for the steps that can still be cancelled (quit and back up).
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Quits and reopens Claude copies for a move. Behind a protocol so tests never touch a real app.
/// Implementations never force-quit and never touch a copy the write allowlist doesn't permit.
public protocol AppControlling: Sendable {
    /// The copy's app, or a `<Name>.real` process of it, is alive.
    func isRunning(_ copy: InstanceRef) -> Bool
    /// A normal quit. Returns when the app and its `.real` process are gone; throws `didntQuit` after the timeout.
    func quit(_ copy: InstanceRef, cancelled: @Sendable () -> Bool) throws
    /// Opens the copy's `Claude-<slug>.app` (or `Claude.app`).
    func reopen(_ copy: InstanceRef) throws
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

/// The real thing: `NSRunningApplication.terminate()` (a normal quit), an AppleScript `quit` by bundle id
/// as a fallback, and `NSWorkspace.openApplication(at:)` on the copy's app bundle. Never `forceTerminate`, never `kill`.
public final class SystemAppController: AppControlling {
    public let policy: WritePolicy
    let running: RunningAppsProviding
    let realProcesses: RealProcessChecking
    public let quitTimeout: TimeInterval
    /// Seconds of waiting before the AppleScript `quit` is sent as well.
    public let fallbackAfter: TimeInterval
    public let pollInterval: TimeInterval

    public init(policy: WritePolicy,
                running: RunningAppsProviding = WorkspaceRunningApps(),
                realProcesses: RealProcessChecking = SystemRealProcesses(),
                quitTimeout: TimeInterval = 90, fallbackAfter: TimeInterval = 4, pollInterval: TimeInterval = 0.4) {
        self.policy = policy; self.running = running; self.realProcesses = realProcesses
        self.quitTimeout = quitTimeout; self.fallbackAfter = fallbackAfter; self.pollInterval = pollInterval
    }

    public func isRunning(_ copy: InstanceRef) -> Bool {
        running.isRunning(bundleID: copy.bundleID) || realProcesses.hasRealProcess(appURL: URL(fileURLWithPath: copy.appPath))
    }

    private func check(_ copy: InstanceRef) throws {
        guard policy.allows(slug: copy.slug) else { throw AppControlError.notAllowed(copy.name) }
    }

    public func quit(_ copy: InstanceRef, cancelled: @Sendable () -> Bool) throws {
        try check(copy)
        guard isRunning(copy) else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: copy.bundleID).filter { !$0.isTerminated }
        for a in apps { _ = a.terminate() }
        var fallback = apps.isEmpty
        if fallback { Self.appleScriptQuit(bundleID: copy.bundleID) }
        let start = Date()
        while isRunning(copy) {
            if cancelled() { throw AppControlError.cancelled }
            let t = Date().timeIntervalSince(start)
            if t > quitTimeout { throw AppControlError.didntQuit(copy.name) }
            if !fallback && t > fallbackAfter { fallback = true; Self.appleScriptQuit(bundleID: copy.bundleID) }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    public func reopen(_ copy: InstanceRef) throws {
        try check(copy)
        let url = URL(fileURLWithPath: copy.appPath)
        guard url.pathExtension == "app", !url.path.contains(".real"),
              FileManager.default.fileExists(atPath: url.path) else { throw AppControlError.cantReopen(copy.name) }
        if isRunning(copy) { return }
        let sem = DispatchSemaphore(value: 0)
        let failure = Box<Error?>(nil)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            failure.value = error
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 30) == .success, failure.value == nil else { throw AppControlError.cantReopen(copy.name) }
    }

    /// `tell application id "<bundle id>" to quit`. The id comes from our own catalog; anything odd is refused.
    static func appleScriptQuit(bundleID: String) {
        guard !bundleID.isEmpty, bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application id \"\(bundleID)\" to quit"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate() }
    }
}

/// What an orchestrated operation did to the apps around it.
public struct MoveOutcome: Sendable {
    public var record: MoveRecord
    /// Copies that were quit.
    public var quit: [InstanceRef]
    /// Copies that could not be reopened afterwards. The operation itself is done.
    public var reopenFailed: [InstanceRef]
    public init(record: MoveRecord, quit: [InstanceRef] = [], reopenFailed: [InstanceRef] = []) {
        self.record = record; self.quit = quit; self.reopenFailed = reopenFailed
    }
}
