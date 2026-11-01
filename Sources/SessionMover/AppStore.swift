import SwiftUI
import AppKit
import Observation
import SessionMoverKit

extension SessionEntry {
    /// Unique per file: the same `local_<id>` can exist in two copies.
    var rowID: String { fileURL.path }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

enum SearchScopeChoice: Hashable { case thisScope, allInstances }

/// The one observable the views read. All logic lives in SessionMoverKit.
@MainActor @Observable
final class AppStore {
    static let shared = AppStore()

    let env = SMEnvironment.fromProcess()
    @ObservationIgnored let engine: MoveEngine
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchedPaths: [URL] = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private let launcher = CopyLauncher()

    var library = Library()
    var settings = AppSettings()
    /// The copies moves may write to (`WritePolicy`). Settings edits it; the engine follows.
    var writePolicy: WritePolicy
    var isLoaded = false
    var isScanning = false

    var scope: Scope = .all { didSet { if scope != oldValue { selection = [] } } }
    var filter: SessionFilter = .active
    var sort: SessionSort = .lastActivity
    var groupByProject = true
    var search = ""
    var searchScopeChoice: SearchScopeChoice = .thisScope
    var selection: Set<String> = []
    var showInspector = false
    var showFirstRun = false
    var showHiddenCallout = false
    var renamingAccount: String?
    var expandedInstances: Set<String> = []
    var collapsedGroups: [Scope: Set<String>] = [:]
    var alertMessage: String?

    // Moves (Phase 2)
    var moveSession: MoveSession? { didSet { if moveSession == nil && oldValue != nil { sheetClosed() } } }
    var toast: Toast?
    var history: [HistoryEntry] = []
    var showMovePicker = false
    var showCopyPicker = false
    /// Option is held during a drag: the drop opens a copy.
    var optionDown = false
    /// A recovery sheet is on its way at launch; the first-run sheet waits for it.
    var launchRecovery = false
    var pendingFirstRun = false
    var showEmptyHistoryConfirm = false
    var lastUndo: MoveRecord?
    var isMoving = false
    // Drag and drop
    var dragRowIDs: [String] = []
    var dropTarget: Scope?
    var dropBadge: String?
    var springOpened: Set<String> = []
    /// The collapsed instance row that is blinking before it springs open.
    var springBlink: String?
    @ObservationIgnored var dragPlans: [Scope: MovePlan] = [:]
    @ObservationIgnored var dragCopyPlans: [Scope: CopyPlan] = [:]
    @ObservationIgnored var recoverySkipped: Set<String> = []
    @ObservationIgnored var springTask: Task<Void, Never>?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var quitAfterMove = false

    init() {
        scanner = LibraryScanner(env: env)
        settingsStore = SettingsStore(env: env)
        let loaded = settingsStore.load()
        settings = loaded
        engine = MoveEngine(env: env, labels: loaded.labels)
        writePolicy = engine.policy
        history = engine.history()
        observeWorkspace()
        installSpaceKey()
        rescan(initial: true)
        // Before anything else: a move a crash or power loss left unfinished.
        if !engine.recoverableMoves().isEmpty { pendingFirstRun = !loaded.firstRunCompleted; presentNextRecovery() }
    }

    private func sheetClosed() {
        if launchRecovery { presentNextRecovery() }
    }

    // MARK: Scanning

    func rescan(initial: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        let scanner = scanner
        Task {
            let lib = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
            library = lib
            isScanning = false
            if expandedInstances.isEmpty { expandedInstances = Set(lib.instances.map(\.id)) }
            if let i = scope.instanceID, lib.scan(i) == nil { scope = .all }
            updateWatcher()
            if initial {
                isLoaded = true
                if !settings.firstRunCompleted && !launchRecovery && !pendingFirstRun { showFirstRun = true }
            }
        }
    }

    private func updateWatcher() {
        let paths = scanner.watchPaths(for: library)
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        watcher?.stop()
        watcher = FolderWatcher(paths: paths, latency: 0.8) { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
    }

    private func scheduleRescan() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { rescan() }
        }
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier?.hasPrefix(Bundles.original) == true else { return }
                Task { @MainActor in self?.scheduleRescan() }
            })
        }
    }

    // MARK: Names

    func accountName(_ id: String) -> String { settings.labels.display(account: id) }
    func orgName(_ id: String) -> String { settings.labels.display(org: id) }
    func isLabelled(_ id: String) -> Bool { settings.labels.name(forAccount: id) != nil }
    func instanceName(_ id: String) -> String { library.instance(id)?.name ?? "Claude" }
    func accountPhrase(_ id: String) -> String { isLabelled(id) ? "\(accountName(id)) account" : "account \(accountName(id))" }

    func setAccountLabel(_ id: String, _ name: String) {
        settings.labels.setAccount(id, name: name)
        saveSettings()
    }

    func saveSettings() {
        engine.labels = settings.labels
        do { try settingsStore.save(settings) } catch { alertMessage = "Couldn't save names: \(error.localizedDescription)" }
    }

    func setOrgLabel(_ id: String, _ name: String) {
        settings.labels.setOrg(id, name: name)
        saveSettings()
    }

    // MARK: Settings

    func setMenuBarExtra(_ on: Bool) {
        // SwiftUI sets the `isInserted` binding itself; writing an unchanged value would re-render in a loop.
        guard settings.menuBarExtraEnabled != on else { return }
        settings.showMenuBarExtra = on
        saveSettings()
    }

    /// `SM_ALLOW` wins over the Settings list, so Settings can't change anything while it is set.
    var policyLockedByEnvironment: Bool { WritePolicy.isOverriddenByEnvironment() }

    func movesAllowed(_ i: Instance) -> Bool { writePolicy.allows(i) }

    /// Turns moves in and out of one copy on or off. Turning on is confirmed by the caller first.
    func setMovesAllowed(_ on: Bool, for i: Instance) {
        guard !policyLockedByEnvironment else { return }
        var slugs: Set<String>
        switch writePolicy.allowed {
        case .all: slugs = Set(library.instances.map { $0.instance.writeSlug.lowercased() })
        case .slugs(let s): slugs = s
        }
        let slug = i.writeSlug.lowercased()
        if on { slugs.insert(slug) } else { slugs.remove(slug) }
        settings.writableInstances = WritePolicy.settingsList(enabling: slugs)
        saveSettings()
        let policy = WritePolicy(allowed: .slugs(slugs))
        engine.updatePolicy(policy)
        writePolicy = policy
    }

    /// Bytes of backups on disk and the number of moves they belong to.
    var backupsSummary: String { historySummary }

    // MARK: Version check (FormatGuard)

    func isVerified(_ i: Instance) -> Bool { engine.formatGuard.isVerified(i.version) }

    /// Copies in the current scope whose app version isn't verified.
    var unverifiedInScope: [Instance] {
        if scope == .history { return [] }
        let ids: [String]
        if let i = scope.instanceID { ids = [i] } else { ids = Array(Set(library.entries(in: scope).map(\.instanceID))) }
        let order = library.instances.map(\.id)
        return ids.compactMap { library.instance($0) }.filter { !isVerified($0) }
            .sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
    }

    func completeFirstRun() {
        settings.firstRunCompleted = true
        saveSettings()
        showFirstRun = false
        if !library.entries(in: .hidden).isEmpty {
            scope = .hidden
            if !settings.hiddenCalloutDismissed { showHiddenCallout = true }
        }
    }

    func dismissHiddenCallout() {
        showHiddenCallout = false
        settings.hiddenCalloutDismissed = true
        saveSettings()
    }

    // MARK: Query

    var query: SessionQuery {
        var q = SessionQuery()
        q.scope = scope; q.filter = filter; q.sort = sort; q.search = search
        q.searchAllInstances = searchScopeChoice == .allInstances
        return q
    }
    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    var results: [SessionEntry] { library.results(for: query) }
    var groups: [ProjectGroup] { groupByProject ? Library.group(results) : [] }
    func count(_ f: SessionFilter) -> Int { library.count(for: f, query: query) }

    /// Rows show the instance tile wherever more than one copy can appear.
    var showsInstanceTile: Bool { scope.isSmartList || (isSearching && searchScopeChoice == .allInstances) }

    var selectedEntries: [SessionEntry] {
        let ids = selection
        if ids.isEmpty { return [] }
        return results.filter { ids.contains($0.rowID) }
    }

    var scopeNoun: String {
        switch scope {
        case .account, .org: "this account"
        case .instance: "this instance"
        default: "this list"
        }
    }
    var scopeSearchLabel: String {
        switch scope {
        case .account, .org: "This Account"
        case .instance: "This Instance"
        default: "This List"
        }
    }

    var title: String {
        switch scope {
        case .all: return "All Sessions"
        case .hidden: return "Hidden in Their App"
        case .running: return "Running"
        case .needsAttention: return "Needs Attention"
        case .history: return "History"
        case .instance(let i): return instanceName(i)
        case .account(let i, let a): return "\(instanceName(i)) · \(accountName(a))"
        case .org(let i, let a, let o): return "\(instanceName(i)) · \(accountName(a)) · \(orgName(o))"
        }
    }

    var subtitle: String {
        if scope == .history { return historySummary }
        let all = library.entries(in: scope)
        let archived = all.filter { $0.summary?.isArchived == true }.count
        var parts: [String] = []
        if case .account(_, let a) = scope { parts.append(accountName(a)) }
        parts.append("\(all.count) sessions")
        if archived > 0 { parts.append("\(archived) archived") }
        if case .account(let i, let a) = scope, library.scan(i)?.signedInAccountID != a { parts.append("hidden in \(instanceName(i))") }
        let picked = selectedEntries.count
        if picked > 1 { parts.append("\(picked) selected") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    func isCollapsed(_ group: String) -> Bool { collapsedGroups[scope]?.contains(group) ?? false }
    func toggleGroup(_ group: String) {
        var s = collapsedGroups[scope] ?? []
        if s.contains(group) { s.remove(group) } else { s.insert(group) }
        collapsedGroups[scope] = s
    }

    func openInItsApp(_ entry: SessionEntry) {
        guard let inst = library.instance(entry.instanceID) else { return }
        Task {
            do { try await launcher.openInItsApp(entry, in: inst) }
            catch { alertMessage = error.localizedDescription }
        }
    }

    func openApp(_ instance: Instance) {
        guard instance.appInstalled else { alertMessage = "\(instance.name) isn't installed in Applications."; return }
        Task { _ = try? await NSWorkspace.shared.openApplication(at: instance.appURL, configuration: .init()) }
    }

    func reveal(_ entry: SessionEntry) { launcher.reveal(entry) }

    func reveal(_ instance: Instance) {
        let fm = FileManager.default
        if instance.appInstalled { NSWorkspace.shared.activateFileViewerSelecting([instance.appURL]); return }
        var u = instance.dataURL
        while !fm.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    func copyID(_ entries: [SessionEntry]) {
        let text = entries.map(\.id).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Keyboard during a drag

    /// Space while hovering a collapsed instance springs it open at once, as in Finder.
    private func installSpaceKey() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49, let self, !self.dragRowIDs.isEmpty,
                  case .instance(let i)? = self.dropTarget, !self.expandedInstances.contains(i) else { return event }
            self.expandedInstances.insert(i)
            self.springOpened.insert(i)
            return nil
        }
    }

    /// ⌘F: puts the cursor in the toolbar search field.
    func focusSearch() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
            return
        }
        func find(_ v: NSView) -> NSSearchField? {
            if let f = v as? NSSearchField { return f }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        if let root = window.contentView?.superview, let f = find(root) { window.makeFirstResponder(f) }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Scope to one session's account in its own copy and select it.
    func show(_ entry: SessionEntry) {
        scope = .account(instance: entry.instanceID, account: entry.accountID)
        filter = .all
        search = ""
        selection = [entry.rowID]
    }

    func openSelectionInItsApp() { if let e = selectedEntries.first, selectedEntries.count == 1 { openInItsApp(e) } }
    func revealSelection() { if let e = selectedEntries.first, selectedEntries.count == 1 { reveal(e) } }
}
