import SwiftUI
import SessionMoverKit

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: Binding<Scope?>(get: { store.scope }, set: { if let v = $0 { store.scope = v } })) {
            Section("Library") {
                LibraryRow(title: "All Sessions", symbol: "tray.full", count: store.library.entries(in: .all).count).tag(Scope.all)
                LibraryRow(title: "Hidden in Their App", symbol: "eye.slash", count: store.library.entries(in: .hidden).count)
                    .tag(Scope.hidden)
                    .popover(isPresented: $store.showHiddenCallout, arrowEdge: .trailing) { HiddenCallout() }
                LibraryRow(title: "Running", symbol: "dot.radiowaves.left.and.right", count: store.library.entries(in: .running).count).tag(Scope.running)
                LibraryRow(title: "Needs Attention", symbol: "exclamationmark.triangle", count: store.library.entries(in: .needsAttention).count).tag(Scope.needsAttention)
            }
            Section("History") {
                LibraryRow(title: "History", symbol: "clock.arrow.circlepath", count: store.history.count, badge: store.unfinishedMoves)
                    .tag(Scope.history)
            }
            Section("Instances") {
                ForEach(store.library.instances) { scan in
                    DisclosureGroup(isExpanded: expanded(scan.id)) {
                        ForEach(scan.accountIDs, id: \.self) { a in
                            AccountRow(scan: scan, account: a)
                                .sessionDropTarget(.account(instance: scan.id, account: a), signedInOf: scan.signedInAccountID == a ? scan.id : nil)
                                .tag(Scope.account(instance: scan.id, account: a))
                            let orgs = scan.orgIDs(in: a)
                            if orgs.count > 1 {
                                ForEach(orgs, id: \.self) { o in
                                    OrgRow(scan: scan, account: a, org: o)
                                        .sessionDropTarget(.org(instance: scan.id, account: a, org: o))
                                        .tag(Scope.org(instance: scan.id, account: a, org: o))
                                }
                            }
                        }
                    } label: {
                        InstanceRow(scan: scan)
                            .sessionDropTarget(.instance(scan.id))
                            .tag(Scope.instance(scan.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            if case .account(_, let a) = store.scope { store.renamingAccount = a; return .handled }
            return .ignored
        }
        .safeAreaInset(edge: .bottom) {
            if store.isLoaded && store.library.instances.count == 1 {
                Text("**Only one instance found.** Instances you make with Claude Profiles show up here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { store.expandedInstances.contains(id) },
                set: { if $0 { store.expandedInstances.insert(id) } else { store.expandedInstances.remove(id) } })
    }
}

private struct HiddenCallout: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        let hidden = store.library.entries(in: .hidden)
        let copies = Set(hidden.map(\.instanceID)).compactMap { store.library.instance($0)?.name }.sorted()
        VStack(alignment: .leading, spacing: 8) {
            Text("\(hidden.count) sessions are hidden").font(.headline)
            Text("\(copies.joined(separator: ", ")) is signed in to a different account, so Claude shows only that account's sessions. Session Mover shows all of them.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("OK") { store.dismissHiddenCallout() }.keyboardShortcut(.defaultAction) }
        }
        .padding(14).frame(width: 280)
    }
}

private struct LibraryRow: View {
    let title: String
    let symbol: String
    let count: Int
    var badge = 0
    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if badge > 0 { Text("\(badge)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 5).background(Color.orange, in: Capsule()) }
            Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge > 0 ? "\(title), \(count), \(badge) need attention" : "\(title), \(count)\(symbol == "clock.arrow.circlepath" ? "" : " sessions")")
    }
}

private struct InstanceRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scan: InstanceScan

    var body: some View {
        let i = scan.instance
        let running = store.library.isRunning(i)
        let busy = store.library.hasBusySession(i)
        let verified = store.isVerified(i)
        HStack(spacing: 8) {
            InstanceTile(instance: i, size: 20)
            Text(i.name).lineLimit(1)
            Spacer(minLength: 4)
            if !verified {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("\(FormatGuard.unverifiedPhrase(i)). Moves in and out of it use Open a Copy only.")
            }
            if scan.scanError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help("\(i.name) could not be read")
            } else if busy {
                Image(systemName: "circle.dotted").symbolEffect(.pulse, isActive: !reduceMotion).foregroundStyle(.secondary).help("Running, a session is busy")
            } else if running {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary).help("Running")
            }
            Text("\(scan.entries.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(minHeight: 28)
        .opacity(store.springBlink == i.id ? 0.3 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(i.name), instance, \(scan.scanError != nil ? "could not be read" : running ? (busy ? "running, a session is busy" : "running") : "not running")\(verified ? "" : ", moves use Open a Copy only")")
        .accessibilityValue("\(scan.accountIDs.count) accounts, \(scan.entries.count) sessions")
        .contextMenu {
            Button("Open \(i.name)") { store.openApp(i) }.disabled(!i.appInstalled)
            Button("Show in Finder") { store.reveal(i) }
        }
    }
}

private struct AccountRow: View {
    @Environment(AppStore.self) private var store
    let scan: InstanceScan
    let account: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let signedIn = scan.signedInAccountID == account
        let count = scan.entries.filter { $0.accountID == account }.count
        let labelled = store.isLabelled(account)
        let name = store.accountName(account)
        let i = scan.instance.name
        HStack(spacing: 6) {
            Image(systemName: signedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(signedIn ? Color.accentColor : Color.secondary)
            if store.renamingAccount == account {
                TextField("Name or email", text: $draft)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { store.renamingAccount = nil }
                    .onAppear { draft = store.settings.labels.name(forAccount: account) ?? ""; focused = true }
            } else if labelled {
                Text(name).lineLimit(1)
            } else {
                Text.mono(name).foregroundStyle(.secondary)
                Button("Name…") { store.renamingAccount = account }.buttonStyle(.link).font(.system(size: 11))
            }
            Spacer(minLength: 4)
            Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            if !signedIn { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
        }
        .frame(minHeight: 26)
        .help(signedIn ? "Signed in to \(i) now" : hiddenHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(labelled ? name : "Account \(name)"), account in \(i), \(signedIn ? "signed in" : "not signed in")")
        .accessibilityValue(signedIn ? "\(count) sessions" : "\(count) sessions, hidden in \(i)")
        .contextMenu { Button("Name…") { store.renamingAccount = account } }
    }

    private var hiddenHelp: String {
        let i = scan.instance.name
        if let now = scan.signedInAccountID { return "Hidden in \(i). \(i) is signed in to \(store.accountPhrase(now))." }
        return "Hidden in \(i). \(i) isn't signed in."
    }

    private func commit() {
        store.setAccountLabel(account, draft)
        store.renamingAccount = nil
    }
}

private struct OrgRow: View {
    @Environment(AppStore.self) private var store
    let scan: InstanceScan
    let account: String
    let org: String
    var body: some View {
        let count = scan.entries.filter { $0.accountID == account && $0.orgID == org }.count
        HStack(spacing: 6) {
            Image(systemName: "building.2").foregroundStyle(.secondary)
            Text(store.orgName(org)).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.leading, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Organization \(store.orgName(org)), \(count) sessions")
    }
}
