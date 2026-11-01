import SwiftUI
import SessionMoverKit

/// Move To ▸ <instance ▸ account>. Used by the row context menu and the Session menu.
/// Takes the store explicitly: it is also used from `Commands`, which don't receive the environment.
struct MoveToMenu: View {
    let store: AppStore
    let entries: [SessionEntry]

    var body: some View {
        Menu("Move To") {
            ForEach(store.library.instances) { scan in
                Menu(scan.instance.name) {
                    ForEach(store.destinationAccounts(scan), id: \.self) { a in
                        let current = store.isCurrent(entries, instance: scan.id, account: a)
                        let signedIn = scan.signedInAccountID == a
                        Button("\(store.accountName(a))\(current ? " (Current)" : signedIn ? " (Signed In)" : "")") {
                            store.beginMove(entries, to: MoveDestination(instanceID: scan.id, accountID: a))
                        }.disabled(current)
                    }
                    if store.destinationAccounts(scan).isEmpty { Text("Not signed in") }
                }
            }
        }
        .disabled(entries.isEmpty || store.isMoving)
        Menu("Open a Copy In") {
            if entries.count > 1 {
                // Disabled with its reason: the submenu opens and says why.
                Text("Open a copy works on one session at a time.")
            } else {
                ForEach(store.library.instances) { scan in
                    if let a = scan.signedInAccountID {
                        let current = entries.count == 1 && store.isCurrent(entries, instance: scan.id, account: a)
                        Button("\(scan.instance.name) ▸ \(store.accountName(a))\(current ? " (Current)" : "")") {
                            store.beginCopy(entries[0], to: MoveDestination(instanceID: scan.id, accountID: a))
                        }.disabled(current)
                    }
                }
            }
        }
        .disabled(entries.isEmpty || store.isMoving)
    }
}

/// ⇧⌘M: a destination picker with type-to-filter.
struct MovePickerView: View {
    @Environment(AppStore.self) private var store
    /// ⌥⇧⌘M: Open a Copy In…, one destination per copy (the account it is signed in to).
    var copy = false
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Choice: Identifiable {
        let id: String
        let label: String
        let current: Bool
        let destination: MoveDestination
    }

    private var entries: [SessionEntry] { store.selectedEntries }

    private var choices: [Choice] {
        var out: [Choice] = []
        for scan in store.library.instances {
            for a in (copy ? [scan.signedInAccountID].compactMap { $0 } : store.destinationAccounts(scan)) {
                let cur = store.isCurrent(entries, instance: scan.id, account: a)
                let signed = scan.signedInAccountID == a
                out.append(Choice(id: "\(scan.id)|\(a)", label: "\(store.destinationLabel(scan, a))\(cur ? " (Current)" : signed ? " (Signed In)" : "")",
                                  current: cur, destination: MoveDestination(instanceID: scan.id, accountID: a)))
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? out : out.filter { $0.label.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy ? "Open a copy of \"\(entries.first?.displayTitle ?? "")\" in…"
                      : entries.count == 1 ? "Move \"\(entries[0].displayTitle)\" to…" : "Move \(entries.count) Sessions to…")
                .font(.headline).lineLimit(1)
            TextField("Filter destinations", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let c = choices.first(where: { !$0.current }) { pick(c) } }
            List(choices) { c in
                Button { pick(c) } label: { Text(c.label).foregroundStyle(c.current ? .secondary : .primary) }
                    .buttonStyle(.plain).disabled(c.current)
            }
            .frame(height: 220)
            HStack { Spacer(); Button("Cancel") { store.showMovePicker = false; store.showCopyPicker = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(18).frame(width: 420)
        .onAppear { focused = true }
    }

    private func pick(_ c: Choice) {
        store.showMovePicker = false
        store.showCopyPicker = false
        let e = entries
        // Let the picker sheet go before the Move sheet comes up.
        DispatchQueue.main.async {
            if copy, let first = e.first { store.beginCopy(first, to: c.destination) } else { store.beginMove(e, to: c.destination) }
        }
    }
}

struct ToastView: View {
    @Environment(AppStore.self) private var store
    let toast: Toast
    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.system(size: 12)).lineLimit(2)
            ForEach(toast.actions) { a in
                Button(a.title) { a.run() }.buttonStyle(.link).font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .panelBackground(Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .onAppear { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: toast.text]) }
    }
}
