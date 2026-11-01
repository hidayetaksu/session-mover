import Foundation

/// Is a `<Name>.real` process of this copy alive? The launcher in `Contents/MacOS` execs `<Name>.real` with
/// `--user-data-dir`, so a copy can outlive what NSRunningApplication reports. Behind a protocol so tests fake it.
public protocol RealProcessChecking: Sendable {
    func hasRealProcess(appURL: URL) -> Bool
}

public struct SystemRealProcesses: RealProcessChecking {
    public init() {}
    public func hasRealProcess(appURL: URL) -> Bool {
        let exe = appURL.path + "/Contents/MacOS/"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix(exe) {
            let head = line.components(separatedBy: " --")[0]
            if head.contains(".real") { return true }
        }
        return false
    }
}

public struct NoRealProcesses: RealProcessChecking {
    public init() {}
    public func hasRealProcess(appURL: URL) -> Bool { false }
}
