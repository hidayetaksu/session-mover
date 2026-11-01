import SwiftUI
import SessionMoverKit

struct FirstRunView: View {
    @Environment(AppStore.self) private var store
    @State private var step = 1
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if step == 1 { findStep } else { nameStep }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }

    private var accounts: [String] { store.library.accountIDs() }

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finding Claude on this Mac.").font(.title2.weight(.semibold))
            if store.library.instances.isEmpty {
                Text("Claude isn't installed. Session Mover works with the Claude desktop app.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.library.instances) { scan in
                        HStack(spacing: 10) {
                            InstanceTile(instance: scan.instance, size: 24)
                            Text(scan.instance.name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("\(scan.entries.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue") { step = accounts.isEmpty ? 3 : 2; if step == 3 { store.completeFirstRun() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which accounts are these?").font(.title2.weight(.semibold))
            Text("Claude stores account IDs, not emails. Name each one once.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) { ForEach(accounts, id: \.self) { card($0) } }
            }
            HStack {
                Button("Skip for Now") { store.completeFirstRun() }
                Spacer()
                Button("Done") {
                    for (id, n) in names where !n.trimmingCharacters(in: .whitespaces).isEmpty { store.settings.labels.setAccount(id, name: n) }
                    store.completeFirstRun()
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func card(_ id: String) -> some View {
        let signedIn = store.library.instancesSignedIn(to: id)
        let entries = store.library.entries(forAccount: id)
        let perInstance = Dictionary(grouping: entries, by: \.instanceID)
        let counts = store.library.instances.compactMap { s -> String? in
            guard let n = perInstance[s.id]?.count else { return nil }
            return "\(n) in \(s.instance.name)"
        }.joined(separator: ", ")
        let recent = Library.sorted(entries.filter { !$0.isUnreadable }, by: .lastActivity).prefix(3).map(\.displayTitle)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text.mono(AccountLabels.shortID(id), size: 13).fontWeight(.semibold)
                Spacer()
                Text(signedIn.isEmpty ? "Not signed in anywhere now" : "Signed in to \(signedIn.map(\.name).joined(separator: ", ")) now")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Sessions: \(counts.isEmpty ? "none" : counts)").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(recent.enumerated()), id: \.offset) { _, t in
                Text("\"\(t)\"").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                TextField("Name or email", text: Binding(get: { names[id] ?? "" }, set: { names[id] = $0 })).textFieldStyle(.roundedBorder)
                if let first = signedIn.first {
                    Button("Check in \(first.name)") { store.openApp(first) }.buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
