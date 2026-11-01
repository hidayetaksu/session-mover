import SwiftUI
import SessionMoverKit

/// ⌘, : account names, the menu bar extra, which copies moves may touch, and backups.
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            MoveSettings().tabItem { Label("Moves", systemImage: "arrow.right.square") }
        }
        .frame(width: 580, height: 460)
        .environment(store)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    @State private var confirmEmpty = false

    var body: some View {
        Form {
            Section {
                Toggle("Show in the menu bar", isOn: Binding(get: { store.settings.menuBarExtraEnabled }, set: { store.setMenuBarExtra($0) }))
                Text("Shows how many sessions are hidden in their apps and how many are running, with a shortcut to Undo the last move.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Backups") {
                LabeledContent("Kept") { Text(store.backupsSummary).monospacedDigit() }
                Text("Every move backs up the files it changes before touching them. Backups stay until you empty History.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Empty History…") { confirmEmpty = true }
                    .disabled(store.history.allSatisfy { $0.record.state == .started })
            }
        }
        .formStyle(.grouped)
        .onAppear { store.reloadHistory() }
        .confirmationDialog("Empty History?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty History", role: .destructive) { store.emptyHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = store.history.filter { $0.record.state != .started }.count
            Text("Restore won't be possible for these \(n) moves. The sessions stay where they are.")
        }
    }
}

// MARK: Accounts

private struct AccountSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let accounts = store.library.accountIDs()
        let orgs = orgIDs
        Form {
            Section {
                Text("Claude stores account IDs, not emails. Name each one once; the name shows everywhere, in every copy.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Accounts") {
                if accounts.isEmpty { Text("No accounts found yet.").foregroundStyle(.secondary) }
                ForEach(accounts, id: \.self) { a in
                    LabelRow(id: a, detail: accountDetail(a), placeholder: "Name or email",
                             current: store.settings.labels.name(forAccount: a) ?? "") { store.setAccountLabel(a, $0) }
                }
            }
            if !orgs.isEmpty {
                Section("Organizations") {
                    ForEach(orgs, id: \.self) { o in
                        LabelRow(id: o, detail: "", placeholder: "Name",
                                 current: store.settings.labels.name(forOrg: o) ?? "") { store.setOrgLabel(o, $0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var orgIDs: [String] {
        var seen: [String] = []
        for i in store.library.instances { for o in i.orgs where !seen.contains(o.orgID) { seen.append(o.orgID) } }
        return seen
    }

    private func accountDetail(_ a: String) -> String {
        let now = store.library.instancesSignedIn(to: a).map(\.name)
        let n = store.library.entries(forAccount: a).count
        return "\(n) session\(n == 1 ? "" : "s")" + (now.isEmpty ? " · not signed in anywhere now" : " · signed in to \(now.joined(separator: ", ")) now")
    }
}

private struct LabelRow: View {
    let id: String
    let detail: String
    let placeholder: String
    let current: String
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text.mono(AccountLabels.shortID(id))
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(width: 210, alignment: .leading)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(commit)
                .accessibilityLabel("Name for \(id.prefix(8))")
        }
        .onAppear { draft = current }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != current { save(t) }
    }
}

// MARK: Moves

private struct MoveSettings: View {
    @Environment(AppStore.self) private var store
    @State private var asking: Instance?

    var body: some View {
        Form {
            Section {
                Text("Session Mover only changes files in the copies you turn on here. Real copies are off until you turn them on. A move always asks first, backs up what it changes, and can be undone.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.policyLockedByEnvironment {
                    Label("SM_ALLOW is set in the environment, so it decides. This list can't change it.", systemImage: "lock.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Allow moves for") {
                if store.library.instances.isEmpty { Text("No copies of Claude found.").foregroundStyle(.secondary) }
                ForEach(store.library.instances) { scan in row(scan.instance) }
            }
            Section {
                Text("Open a Copy never changes files, so it works for every copy whatever is turned on here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Allow moves for \(asking?.name ?? "this copy")?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible) {
            Button("Allow Moves") { if let i = asking { store.setMovesAllowed(true, for: i) }; asking = nil }
            Button("Cancel", role: .cancel) { asking = nil }
        } message: {
            Text("Session Mover will be able to quit \(asking?.name ?? "this copy"), change session files in its data folder, and reopen it. Each move is backed up first and can be undone from History.")
        }
    }

    private func row(_ i: Instance) -> some View {
        let on = store.movesAllowed(i)
        return Toggle(isOn: Binding(get: { on }, set: { want in
            if want { asking = i } else { store.setMovesAllowed(false, for: i) }
        })) {
            HStack(spacing: 8) {
                InstanceTile(instance: i, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(i.name)
                    Text(on ? "Moves allowed" : "Moves off").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(store.policyLockedByEnvironment)
        .accessibilityLabel("Allow moves for \(i.name)")
        .accessibilityValue(on ? "on" : "off")
    }
}
