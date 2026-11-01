import SwiftUI
import SessionMoverKit

/// Lets ⌘Q through even while a sheet is up. Waits for a move that is in flight so it never stops half-way.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With a sheet showing, AppKit answers the Quit Apple event (Dock, AppleScript) with "User canceled" and
    /// never reaches `applicationShouldTerminate`. Take the event over: end the sheets, then terminate.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        AppStore.shared.quit()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppStore.shared
        if store.isMoving { store.quitAfterMove = true; return .terminateLater }
        return .terminateNow
    }
}

@main
struct SessionMoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared

    var body: some Scene {
        Window("Session Mover", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 680)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open in Its App") { store.openSelectionInItsApp() }
                    .keyboardShortcut("o", modifiers: .command).disabled(store.selectedEntries.count != 1)
                Button("Reveal in Finder") { store.revealSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(store.selectedEntries.count != 1)
                Button("Copy Session ID") { store.copyID(store.selectedEntries) }
                    .disabled(store.selectedEntries.isEmpty)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Session Mover") { store.quit() }.keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoTitle.map { "Undo \($0)" } ?? "Undo") {
                    if Self.isEditingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { store.undoLast() }
                }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                MoveToMenu(store: store, entries: store.selectedEntries)
                Button("Move To…") { store.showMovePicker = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(store.selectedEntries.isEmpty || store.isMoving)
                Button(store.selectedEntries.count > 1 ? "Open a Copy In… (one session at a time)" : "Open a Copy In…") { store.showCopyPicker = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift, .option])
                    .disabled(store.selectedEntries.count != 1 || store.isMoving)
                Divider()
                Button("History") { store.scope = .history }.keyboardShortcut("y", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { store.focusSearch() }.keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(store.showInspector ? "Hide Inspector" : "Show Inspector") { store.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Active") { store.filter = .active }.keyboardShortcut("1", modifiers: .command)
                Button("Archived") { store.filter = .archived }.keyboardShortcut("2", modifiers: .command)
                Button("Running") { store.filter = .running }.keyboardShortcut("3", modifiers: .command)
                Button("Errors") { store.filter = .errors }.keyboardShortcut("4", modifiers: .command)
                Button("All") { store.filter = .all }.keyboardShortcut("0", modifiers: .command)
                Divider()
                Button(store.groupByProject ? "Don't Group by Project" : "Group by Project") { store.groupByProject.toggle() }
                    .keyboardShortcut("g", modifiers: [.command, .control])
                Button("Rescan") { store.rescan() }.keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: Binding(get: { store.settings.menuBarExtraEnabled }, set: { store.setMenuBarExtra($0) })) {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)

        Settings { SettingsView().environment(store) }
    }
}

extension SessionMoverApp {
    @MainActor static var isEditingText: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            SessionListView()
                .frame(minWidth: 380)
                .inspector(isPresented: $store.showInspector) { InspectorView() }
        }
        .sheet(isPresented: $store.showFirstRun) { FirstRunView().environment(store) }
        .sheet(item: $store.moveSession) { MoveSheetView(session: $0).environment(store) }
        .sheet(isPresented: $store.showMovePicker) { MovePickerView().environment(store) }
        .sheet(isPresented: $store.showCopyPicker) { MovePickerView(copy: true).environment(store) }
        .alert("Session Mover", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("Close") { store.alertMessage = nil }
        } message: { Text(store.alertMessage ?? "") }
    }
}
