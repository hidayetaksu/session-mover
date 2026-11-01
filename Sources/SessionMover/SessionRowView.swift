import SwiftUI
import SessionMoverKit

struct SessionRowView: View {
    let entry: SessionEntry
    let library: Library
    let instance: Instance?
    let showTile: Bool
    var now: Date = .now

    private var chips: [StateChip] { library.chips(for: entry) }
    private var summary: SessionSummary? { entry.summary }

    var body: some View {
        HStack(spacing: 8) {
            if showTile, let instance { InstanceTile(instance: instance, size: 16) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayTitle)
                        .font(.system(size: 13))
                        .lineLimit(1).truncationMode(.tail)
                        .opacity(summary?.isArchived == true ? 0.7 : 1)
                    if summary?.isStarred == true {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 8)
                    if let d = summary?.lastActivityAt {
                        Text(RelativeTime.string(for: d, now: now))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    line2.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    ForEach(Array(chips.prefix(3)), id: \.self) { ChipView(chip: $0) }
                    if chips.count > 3 { Text("+\(chips.count - 3)").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var line2: Text {
        if let err = entry.readError, entry.isUnreadable { return Text("\(entry.fileURL.lastPathComponent) isn't valid (\(err)).") }
        var t = Text(entry.folderName ?? "No folder")
        if let b = entry.branchOrWorktree { t = t + Text(" · ") + Text(b).font(.system(size: 11, design: .monospaced)) }
        return t
    }

    private var accessibilityText: String {
        let name = instance?.name ?? "Claude"
        var parts = [entry.displayTitle + "."]
        if entry.isUnreadable { parts.append("Session file couldn't be read.") }
        else {
            var l = entry.folderName ?? "No folder"
            if let b = entry.branchOrWorktree { l += ", branch \(b)" }
            parts.append(l + ".")
        }
        parts += chips.map { $0.accessibilityLabel(instanceName: name) + "." }
        if let d = summary?.lastActivityAt {
            parts.append(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: now) + ".")
        }
        return parts.joined(separator: " ")
    }
}
