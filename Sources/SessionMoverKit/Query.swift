import Foundation

public enum SessionFilter: String, CaseIterable, Sendable, Identifiable {
    case active, archived, running, errors, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .active: "Active"
        case .archived: "Archived"
        case .running: "Running"
        case .errors: "Errors"
        case .all: "All"
        }
    }
}

public enum SessionSort: String, CaseIterable, Sendable, Identifiable {
    case lastActivity, title, project, created
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lastActivity: "Last Activity"
        case .title: "Title"
        case .project: "Project"
        case .created: "Created"
        }
    }
}

public struct ProjectGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let pathTail: String?
    public let entries: [SessionEntry]
}

public struct SessionQuery: Sendable {
    public var scope: Scope = .all
    public var filter: SessionFilter = .active
    public var sort: SessionSort = .lastActivity
    public var search = ""
    /// When searching: look in every copy instead of the selected scope.
    public var searchAllInstances = false
    public init() {}
}

extension Library {
    public func matches(_ e: SessionEntry, filter: SessionFilter) -> Bool {
        switch filter {
        case .all: return true
        case .active: return e.summary.map { !$0.isArchived } ?? false
        case .archived: return e.summary?.isArchived ?? false
        case .running: return isLive(e)
        case .errors: return needsAttention(e)
        }
    }

    /// Entries of a scope with the search applied (scope counts per filter use `count(in:filter:search:)`).
    private func base(_ q: SessionQuery) -> [SessionEntry] {
        let scope: Scope = (!q.search.trimmingCharacters(in: .whitespaces).isEmpty && q.searchAllInstances) ? .all : q.scope
        let needle = q.search.trimmingCharacters(in: .whitespaces)
        let all = entries(in: scope)
        return needle.isEmpty ? all : all.filter { Self.matches($0, search: needle) }
    }

    public func count(for filter: SessionFilter, query q: SessionQuery) -> Int {
        base(q).filter { matches($0, filter: filter) }.count
    }

    public func results(for q: SessionQuery) -> [SessionEntry] {
        Self.sorted(base(q).filter { matches($0, filter: q.filter) }, by: q.sort)
    }

    /// Search over title, folder, branch, PR number (`#843`), model and ids.
    public static func matches(_ e: SessionEntry, search: String) -> Bool {
        let needle = search.lowercased()
        guard let s = e.summary else { return e.fileURL.lastPathComponent.lowercased().contains(needle) }
        var hay = [e.displayTitle, e.id, s.cliSessionId ?? "", s.cwd ?? "", s.originCwd ?? "", s.branch ?? "",
                   s.worktreeName ?? "", s.model ?? ""]
        hay += s.prNumbers.map { "#\($0)" }
        if hay.contains(where: { $0.lowercased().contains(needle) }) { return true }
        return false
    }

    public static func sorted(_ entries: [SessionEntry], by sort: SessionSort) -> [SessionEntry] {
        func date(_ e: SessionEntry, _ kp: KeyPath<SessionSummary, Date?>) -> Date { e.summary?[keyPath: kp] ?? .distantPast }
        switch sort {
        case .lastActivity: return entries.sorted { date($0, \.lastActivityAt) > date($1, \.lastActivityAt) }
        case .created: return entries.sorted { date($0, \.createdAt) > date($1, \.createdAt) }
        case .title: return entries.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .project:
            return entries.sorted {
                let a = ($0.folderName ?? "~"), b = ($1.folderName ?? "~")
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
                return date($0, \.lastActivityAt) > date($1, \.lastActivityAt)
            }
        }
    }

    /// Groups sorted entries by project folder, keeping first-appearance order.
    public static func group(_ entries: [SessionEntry]) -> [ProjectGroup] {
        var order: [String] = []
        var buckets: [String: [SessionEntry]] = [:]
        for e in entries {
            let key = e.isUnreadable ? "\u{0}unreadable" : (e.summary?.projectPath ?? "\u{0}nofolder")
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(e)
        }
        return order.map { key in
            switch key {
            case "\u{0}unreadable": return ProjectGroup(id: key, name: "Unreadable files", pathTail: nil, entries: buckets[key]!)
            case "\u{0}nofolder": return ProjectGroup(id: key, name: "No folder", pathTail: nil, entries: buckets[key]!)
            default:
                let ns = key as NSString
                let parent = ns.deletingLastPathComponent
                let tail = (parent as NSString).lastPathComponent
                return ProjectGroup(id: key, name: ns.lastPathComponent, pathTail: tail.isEmpty ? nil : ".../\(tail)", entries: buckets[key]!)
            }
        }
    }
}
