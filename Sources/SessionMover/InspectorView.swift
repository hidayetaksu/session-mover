import SwiftUI
import SessionMoverKit

struct InspectorView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let sel = store.selectedEntries
        Group {
            if sel.count == 1, let e = sel.first { Detail(entry: e) }
            else if sel.count > 1 {
                Summary(entries: sel)
            } else {
                ContentUnavailableView("No session selected", systemImage: "sidebar.trailing")
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 300, max: 340)
    }

    /// Several rows selected: what is in the selection and what it can do.
    private struct Summary: View {
        @Environment(AppStore.self) private var store
        let entries: [SessionEntry]
        var body: some View {
            let perInstance = Dictionary(grouping: entries, by: \.instanceID)
            let order = store.library.instances.map(\.id).filter { perInstance[$0] != nil }
            let archived = entries.filter { $0.summary?.isArchived == true }.count
            let live = entries.filter { store.library.isLive($0) }.count
            VStack(alignment: .leading, spacing: 10) {
                Label("\(entries.count) sessions selected", systemImage: "square.stack").font(.system(size: 15, weight: .semibold))
                Divider()
                ForEach(order, id: \.self) { id in
                    HStack(spacing: 8) {
                        if let i = store.library.instance(id) { InstanceTile(instance: i, size: 16) }
                        Text(store.instanceName(id)).font(.system(size: 12))
                        Spacer()
                        Text("\(perInstance[id]?.count ?? 0)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if archived > 0 || live > 0 {
                    Divider()
                    if live > 0 { Text("\(live) running or busy. Running sessions can't move while busy.").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if archived > 0 { Text("\(archived) archived").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Divider()
                Text("Drag them onto an account, or use Move To (⇧⌘M). Open a copy works on one session at a time.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private struct Detail: View {
        @Environment(AppStore.self) private var store
        let entry: SessionEntry
        var body: some View {
            let inst = store.library.instance(entry.instanceID)
            let s = entry.summary
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Rectangle().fill(Color(hex: inst?.accentHex ?? "#8E8E93")).frame(width: 3)
                        Text(entry.displayTitle).font(.system(size: 15, weight: .semibold)).lineLimit(3)
                    }.padding(12)
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        field("Instance", inst?.name)
                        field("Account", store.accountName(entry.accountID))
                        field("Organization", store.orgName(entry.orgID))
                        Divider().padding(.vertical, 4)
                        field("Folder", s?.projectPath, mono: true)
                        if let c = s?.cwd, c != s?.projectPath { field("Working dir", c, mono: true) }
                        field("Branch", s?.branch, mono: true)
                        field("Worktree", s?.worktreeName, mono: true)
                        field("Model", s?.model)
                        field("Permissions", s?.permissionMode)
                        field("PRs", s.flatMap { $0.prNumbers.isEmpty ? nil : $0.prNumbers.map { "#\($0)" }.joined(separator: " ") })
                        Divider().padding(.vertical, 4)
                        field("Created", s?.createdAt.map(format))
                        field("Last activity", s?.lastActivityAt.map(format))
                        Divider().padding(.vertical, 4)
                        field("Session ID", entry.id, mono: true)
                        field("Claude Code ID", s?.cliSessionId, mono: true)
                        field("Spawned from", s?.spawnedFromID, mono: true)
                        field("Forked from", s?.forkedFromID, mono: true)
                        field("File", entry.fileURL.path, mono: true)
                        field("Problem", entry.readError)
                        field("Error", s?.errorText)
                    }.padding(12)
                    let chips = store.library.chips(for: entry)
                    if !chips.isEmpty {
                        Divider()
                        HStack { ForEach(chips, id: \.self) { ChipView(chip: $0) } }.padding(12)
                    }
                }
            }
        }

        private func format(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

        @ViewBuilder private func field(_ label: String, _ value: String?, mono: Bool = false) -> some View {
            if let value, !value.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .trailing)
                    Text(value).font(.system(size: 11, design: mono ? .monospaced : .default)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
