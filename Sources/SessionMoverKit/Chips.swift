import Foundation

public enum ChipTone: Sendable { case accent, green, orange, yellow, gray, neutral, red }

/// State chips of a session row, in priority order: Busy > Running > Limit > Folder missing > Archived > PRs.
public enum StateChip: Hashable, Sendable {
    case unreadable
    case busy
    case running
    case limit(String?)
    case folderMissing
    case archived
    case prs(Int)
    /// A copy was opened in another copy of Claude (the instance name).
    case copied(String)

    public var priority: Int {
        switch self {
        case .unreadable: 0
        case .busy: 1
        case .running: 2
        case .limit: 3
        case .folderMissing: 4
        case .archived: 5
        case .prs: 6
        case .copied: 7
        }
    }

    public var title: String {
        switch self {
        case .unreadable: "Unreadable"
        case .busy: "Busy"
        case .running: "Open"
        case .limit(let r): r.map { "Limit · \($0)" } ?? "Limit"
        case .folderMissing: "No folder"
        case .archived: "Archived"
        case .prs(let n): "\(n)"
        case .copied: "Copied"
        }
    }

    public var symbol: String {
        switch self {
        case .unreadable: "exclamationmark.triangle.fill"
        case .busy: "circle.dotted"
        case .running: "circle.fill"
        case .limit: "hourglass"
        case .folderMissing: "folder.badge.questionmark"
        case .archived: "archivebox"
        case .prs: "arrow.triangle.pull"
        case .copied: "doc.on.doc"
        }
    }

    public var tone: ChipTone {
        switch self {
        case .unreadable: .red
        case .busy: .accent
        case .running: .green
        case .limit: .orange
        case .folderMissing: .yellow
        case .archived: .gray
        case .prs: .neutral
        case .copied: .neutral
        }
    }

    public func accessibilityLabel(instanceName: String) -> String {
        switch self {
        case .unreadable: "Session file couldn't be read"
        case .busy: "Busy, mid-turn. Can't be moved."
        case .running: "Open and idle in \(instanceName)"
        case .limit(let r): r.map { "Weekly limit reached on this account, resets \($0)" } ?? "Weekly limit reached on this account"
        case .folderMissing: "Working folder no longer exists"
        case .archived: "Archived"
        case .prs(let n): n == 1 ? "1 pull request" : "\(n) pull requests"
        case .copied(let n): "A copy was opened in \(n)"
        }
    }
}

public enum RelativeTime {
    /// "Just now", "2 min ago", "3 h ago", "Yesterday", "Oct 23", "Oct 23, 2025".
    public static func string(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "Just now" }
        if secs < 3600 { return "\(Int(secs / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(secs / 3600)) h ago" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "MMMdy")
        return f.string(from: date)
    }
}
