import SwiftUI
import SessionMoverKit

/// The menu bar extra: counts, the copies, the last move and a shortcut for hidden sessions.
/// Nothing here moves anything: "Move To" opens the main window's Move sheet.
struct MenuBarLabel: View {
    let store: AppStore
    var body: some View {
        let hidden = store.library.entries(in: .hidden).count
        HStack(spacing: 3) {
            Image(systemName: "rectangle.on.rectangle.angled")
            if hidden > 0 { Text("\(hidden)").monospacedDigit() }
        }
        .accessibilityLabel(hidden > 0 ? "Session Mover, \(hidden) hidden sessions" : "Session Mover")
    }
}

struct MenuBarContent: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    private static let recentLimit = 8

    var body: some View {
        let hidden = store.library.entries(in: .hidden)
        let running = store.library.entries(in: .running).count
        Text("\(hidden.count) Hidden in Their App")
        Text("\(running) Running")
        Divider()
        ForEach(store.library.instances) { scan in
            let isRunning = store.library.isRunning(scan.instance)
            Button {
                bringToFront { store.scope = .instance(scan.id) }
            } label: {
                if isRunning { Label("\(scan.instance.name)  (\(scan.entries.count))", systemImage: "circle.fill") }
                else { Text("\(scan.instance.name)  (\(scan.entries.count))") }
            }
            .help(isRunning ? "\(scan.instance.name) is running" : "\(scan.instance.name) is not running")
        }
        Divider()
        if let rec = store.lastUndo {
            Text(lastMoveText(rec))
            Button(store.undoTitle.map { "Undo \($0)" } ?? "Undo") { store.undoLast() }.disabled(store.isMoving)
            Divider()
        }
        if !hidden.isEmpty {
            Menu("Recent Hidden Sessions") {
                let recent = hidden.sorted { ($0.summary?.lastActivityAt ?? .distantPast) > ($1.summary?.lastActivityAt ?? .distantPast) }
                ForEach(recent.prefix(Self.recentLimit), id: \.rowID) { e in
                    Menu(AppStore.clip(e.displayTitle, 40)) {
                        if let dest = destination(for: e) {
                            Button("Move To \(dest.label)…") { bringToFront { store.beginMove([e], to: dest.destination) } }
                                .disabled(store.isMoving)
                        } else {
                            Text("\(store.instanceName(e.instanceID)) isn't signed in")
                        }
                        Button("Show in Session Mover") { bringToFront { store.show(e) } }
                    }
                }
                if hidden.count > Self.recentLimit {
                    Divider()
                    Button("Show All \(hidden.count)…") { bringToFront { store.scope = .hidden } }
                }
            }
        }
        Button("Open Session Mover") { bringToFront {} }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Session Mover") { store.quit() }
    }

    /// Where a hidden session shows up again: the account its own copy is signed in to.
    private func destination(for e: SessionEntry) -> (label: String, destination: MoveDestination)? {
        guard let scan = store.library.scan(e.instanceID), let a = scan.signedInAccountID else { return nil }
        return ("\(scan.instance.name) · \(store.accountName(a))", MoveDestination(instanceID: scan.id, accountID: a))
    }

    private func lastMoveText(_ r: MoveRecord) -> String {
        let to = store.engine.phrase(r.to.name, account: r.toAccountID)
        return r.isCopy ? "Last: copy of \"\(AppStore.clip(r.title, 28))\" in \(to)" : "Last: moved \(r.sessionCount == 1 ? "\"\(AppStore.clip(r.title, 28))\"" : "\(r.sessionCount) sessions") to \(to)"
    }

    private func bringToFront(_ action: () -> Void) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        action()
    }
}
