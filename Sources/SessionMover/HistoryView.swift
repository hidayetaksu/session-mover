import SwiftUI
import SessionMoverKit

struct HistoryView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if store.history.isEmpty {
                EmptyState(title: "No moves yet.", message: "Moves you make show up here, with a backup you can restore.",
                           actionTitle: nil) {}
            } else {
                table
            }
            Divider()
            HStack {
                Text(store.historySummary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Empty History…") { store.showEmptyHistoryConfirm = true }
                    .disabled(store.history.allSatisfy { $0.record.state == .started })
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear { store.reloadHistory() }
        .confirmationDialog("Empty History?", isPresented: Bindable(store).showEmptyHistoryConfirm, titleVisibility: .visible) {
            Button("Empty History", role: .destructive) { store.emptyHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = store.history.filter { $0.record.state != .started }.count
            Text("Restore won't be possible for these \(n) moves. The sessions stay where they are.")
        }
    }

    private var table: some View {
        Table(store.history) {
            TableColumn("When") { h in
                Text(Self.when(h.record.createdAt)).monospacedDigit().foregroundStyle(.secondary)
            }.width(min: 90, ideal: 110)
            TableColumn("Sessions") { h in
                Text(h.record.title).lineLimit(1)
                    .help(h.record.items.map(\.title).joined(separator: "\n"))
            }.width(min: 140, ideal: 200)
            TableColumn("From → To") { h in
                Text("\(store.engine.phrase(h.record.fromNames.joined(separator: ", "), account: h.record.items[0].fromAccountID)) → \(store.engine.phrase(h.record.to.name, account: h.record.toAccountID))")
                    .lineLimit(2).font(.system(size: 12))
            }.width(min: 200, ideal: 300)
            TableColumn("Kind") { h in Text(h.record.isCopy ? "Copy" : "Move") }.width(60)
            TableColumn("Result") { h in
                Text(Self.result(h.record))
                    .foregroundStyle(h.record.state == .started ? Color.orange : Color.primary)
            }.width(min: 80, ideal: 100)
            TableColumn("") { h in action(h) }.width(min: 150, ideal: 170)
        }
    }

    @ViewBuilder private func action(_ h: HistoryEntry) -> some View {
        let r = h.record
        switch r.state {
        case .done:
            if r.isCopy { Button("Archive Copy") { store.beginRestore(r) }.disabled(store.isMoving) }
            else { Button("Restore") { store.beginRestore(r) }.disabled(store.isMoving) }
        case .started:
            HStack(spacing: 6) {
                if store.engine.canFinish(r) { Button("Finish") { store.beginFinish(r) }.disabled(store.isMoving) }
                Button("Roll Back") { store.beginRestore(r) }.disabled(store.isMoving)
            }
        default: EmptyView()
        }
    }

    static func result(_ r: MoveRecord) -> String {
        switch r.state { case .done: "Done"; case .undone: r.isCopy ? "Archived" : "Restored"; case .rolledBack: "Rolled back"; case .started: "Needs attention" }
    }

    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
