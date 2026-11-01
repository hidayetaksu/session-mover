import SwiftUI
import SessionMoverKit

struct SessionListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.scope != .history {
                banners
                ScopeBar()
                Divider()
            }
            content
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let badge = store.dropBadge, let t = store.dropTarget {
                    DropBadgeView(text: badge, refused: store.dropOperation(t) == .forbidden)
                }
                if let toast = store.toast {
                    ToastView(toast: toast).transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 14).padding(.horizontal, 16)
            .animation(reduceMotion ? .linear(duration: 0.15) : .default, value: store.toast?.id)
        }
        .navigationTitle(store.title)
        .navigationSubtitle(store.subtitle)
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search")
        .searchScopes($store.searchScopeChoice) {
            Text(store.scopeSearchLabel).tag(SearchScopeChoice.thisScope)
            Text("All Instances").tag(SearchScopeChoice.allInstances)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    MoveToMenu(store: store, entries: store.selectedEntries)
                } label: {
                    Label("Move To", systemImage: "arrow.right.square")
                } primaryAction: {
                    store.showMovePicker = true
                }
                .disabled(store.selectedEntries.isEmpty || store.isMoving)
                .help("Move To… (⇧⌘M)")
                Button { store.scope = .history } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("History (⌘Y)")
                Button { store.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Rescan (⌘R)")
                Button { store.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the inspector (⌥⌘I)")
            }
        }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        let unverified = store.unverifiedInScope
        if unverified.count == 1, let i = unverified.first {
            Banner(text: "\(FormatGuard.unverifiedPhrase(i)). Use Open a Copy.",
                   detail: "\(i.name) is newer than Session Mover has checked. Moves in and out of it use Open a Copy until Session Mover is updated.",
                   tint: .yellow, symbol: "lock.fill")
        } else if unverified.count > 1 {
            Banner(text: "\(unverified.count) copies aren't verified yet. Use Open a Copy.",
                   detail: unverified.map { "\($0.name) \($0.version ?? "(unknown version)")" }.joined(separator: ", ")
                       + ". Moves in and out of them use Open a Copy until Session Mover is updated.",
                   tint: .yellow, symbol: "lock.fill")
        }
        if case .account(let i, let a) = store.scope, let scan = store.library.scan(i), scan.signedInAccountID != a {
            let n = store.library.entries(in: store.scope).count
            Banner(text: "\(n) sessions are hidden in \(scan.instance.name).",
                   detail: hiddenDetail(scan), tint: .orange, symbol: "eye.slash.fill")
        } else if store.scope == .hidden {
            let n = store.library.entries(in: .hidden).count
            if n > 0 {
                Banner(text: "\(n) sessions are hidden in their apps.",
                       detail: "Each copy of Claude shows only the account it is signed in to. These sessions belong to other accounts.",
                       tint: .orange, symbol: "eye.slash.fill")
            }
        }
        let unreadable = store.library.entries(in: store.scope).filter(\.isUnreadable).count
        if unreadable > 0 && store.filter != .errors && store.filter != .all {
            Banner(text: "\(unreadable) session \(unreadable == 1 ? "file couldn't" : "files couldn't") be read and \(unreadable == 1 ? "isn't" : "aren't") shown.",
                   tint: .yellow, symbol: "exclamationmark.triangle.fill", actionTitle: "Show Files") { store.filter = .errors }
        }
    }

    private func hiddenDetail(_ scan: InstanceScan) -> String {
        let i = scan.instance.name
        if let now = scan.signedInAccountID {
            return "\(i) is signed in to \(store.accountPhrase(now)), so it shows only that account's sessions."
        }
        return "\(i) isn't signed in to any account, so it shows none of these sessions."
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let results = store.results
        if store.scope == .history {
            HistoryView()
        } else if store.library.instances.isEmpty && store.isLoaded {
            EmptyState(title: "Claude isn't installed.", message: "Session Mover works with the Claude desktop app.",
                       actionTitle: "Get Claude") { NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!) }
        } else if let inst = scopeInstance, let scan = store.library.scan(inst.id), scan.scanError != nil, store.scope == .instance(inst.id) {
            EmptyState(title: "Can't read \(inst.name)'s sessions.", message: scan.scanError ?? "",
                       actionTitle: "Scan Again", secondaryTitle: "Show in Finder") { store.rescan() } secondary: { store.reveal(inst) }
        } else if results.isEmpty && store.isLoaded {
            emptyState
        } else {
            SessionTable(results: results)
        }
    }

    private var scopeInstance: Instance? { store.scope.instanceID.flatMap { store.library.instance($0) } }

    @ViewBuilder private var emptyState: some View {
        let whole = store.library.entries(in: store.scope)
        if store.isSearching {
            EmptyState(title: "No results for \"\(store.search)\" in \(store.searchScopeChoice == .allInstances ? "any instance" : store.scopeNoun).", message: "",
                       actionTitle: store.searchScopeChoice == .allInstances ? nil : "Search All Instances") { store.searchScopeChoice = .allInstances }
        } else if whole.isEmpty, case .instance(let i) = store.scope, let inst = store.library.instance(i) {
            EmptyState(title: "No Code sessions in \(inst.name).", message: "Sessions created in \(inst.name) show up here.",
                       actionTitle: "Open \(inst.name)") { store.openApp(inst) }
        } else if whole.isEmpty {
            EmptyState(title: "No sessions in \(store.scopeNoun).", message: "", actionTitle: nil) {}
        } else {
            let word = store.filter == .all ? "" : store.filter.title.lowercased() + " "
            EmptyState(title: "No \(word)sessions in \(store.scopeNoun).", message: "",
                       actionTitle: store.filter == .all ? nil : "Show All") { store.filter = .all }
        }
    }
}

struct EmptyState: View {
    let title: String
    var message: String
    var actionTitle: String?
    var secondaryTitle: String?
    let action: () -> Void
    var secondary: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            HStack {
                if let secondaryTitle, let secondary { Button(secondaryTitle, action: secondary) }
                if let actionTitle { Button(actionTitle, action: action) }
            }
        }
        .padding(30).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionTable: View {
    @Environment(AppStore.self) private var store
    let results: [SessionEntry]

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            if store.groupByProject {
                ForEach(Library.group(results)) { g in
                    Section {
                        if !store.isCollapsed(g.id) {
                            ForEach(g.entries, id: \.rowID) { row($0) }
                        }
                    } header: { GroupHeader(group: g) }
                }
            } else {
                ForEach(results, id: \.rowID) { row($0) }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            let entries = results.filter { ids.contains($0.rowID) }
            if !entries.isEmpty { MoveToMenu(store: store, entries: entries) }
            if let e = entries.first, entries.count == 1 {
                Button("Open in \(store.instanceName(e.instanceID))") { store.openInItsApp(e) }
                    .disabled(e.summary?.cliSessionId == nil)
                Button("Reveal in Finder") { store.reveal(e) }
            }
            if entries.count > 1 {
                Text("Open a copy works on one session at a time.")
            }
            if !entries.isEmpty {
                Button(entries.count == 1 ? "Copy Session ID" : "Copy Session IDs") { store.copyID(entries) }
            }
        }
    }

    private func row(_ e: SessionEntry) -> some View {
        SessionRowView(entry: e, library: store.library, instance: store.library.instance(e.instanceID), showTile: store.showsInstanceTile)
            .tag(e.rowID)
            .onDrag {
                store.startDrag(e)
                return sessionDragProvider()
            } preview: { DragPreview(entry: e).environment(store) }
            .accessibilityAction(named: "Move To") { if !store.selection.contains(e.rowID) { store.selection = [e.rowID] }; store.showMovePicker = true }
            .accessibilityAction(named: "Open a Copy In") { store.selection = [e.rowID]; store.showCopyPicker = true }
            .accessibilityAction(named: "Open in \(store.instanceName(e.instanceID))") { store.openInItsApp(e) }
            .accessibilityAction(named: "Reveal in Finder") { store.reveal(e) }
    }
}

private struct GroupHeader: View {
    @Environment(AppStore.self) private var store
    let group: ProjectGroup
    var body: some View {
        let collapsed = store.isCollapsed(group.id)
        Button { store.toggleGroup(group.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(.secondary).frame(width: 10)
                Text(group.name).font(.system(size: 13, weight: .semibold))
                if let tail = group.pathTail { Text(tail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text("\(group.entries.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name), \(group.entries.count) sessions, \(collapsed ? "collapsed" : "expanded")")
        .accessibilityHint("Toggles the group")
    }
}

struct ScopeBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 6) {
            ForEach(SessionFilter.allCases) { f in
                let selected = store.filter == f
                Button { store.filter = f } label: {
                    HStack(spacing: 4) {
                        Text(f.title)
                        Text("\(store.count(f))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(f.title), \(store.count(f)) sessions")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
            Menu {
                Picker("Sort", selection: $store.sort) { ForEach(SessionSort.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline)
            } label: { Label("Sort: \(store.sort.title)", systemImage: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
            Toggle(isOn: $store.groupByProject) { Label("Group by Project", systemImage: "folder") }
                .toggleStyle(.button).labelStyle(.iconOnly).help("Group by Project (⌃⌘G)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
