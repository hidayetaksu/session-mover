import SwiftUI
import SessionMoverKit

private struct DisplayRow: Identifiable {
    let id: String
    let status: CheckStatus
    let title: String
    let detail: String?
    let affected: [String]
    var orgChoices: [OrgChoice] = []
}

extension CheckStatus {
    var symbol: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .block: "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self { case .pass: .green; case .warn: .yellow; case .block: .red }
    }
    var spoken: String {
        switch self { case .pass: "Passed"; case .warn: "Warning"; case .block: "Blocked" }
    }
}

struct MoveSheetView: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: MoveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch session.phase {
            case .review: review
            case .running, .finished: progress
            case .failed(let message, let log): failed(message, log)
            }
        }
        .padding(22)
        .frame(width: 520)
        .interactiveDismissDisabled(session.phase == .running || (session.isFinish && session.phase == .review))
        .confirmationDialog("Replace the entry in \(session.plan?.destinationInstance?.name ?? "the destination")?",
                            isPresented: $session.confirmReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { session.replaceConfirmed = true; store.confirm(session) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its entry is backed up first, so Undo brings it back.") }
    }

    // MARK: Header

    private func clip(_ t: String) -> String { AppStore.clip(t, 60) }

    private var title: String {
        switch session.kind {
        case .move(let entries, _):
            entries.count == 1 ? "Move \"\(entries[0].displayTitle)\"" : "Move \(entries.count) Sessions"
        case .restore(let r):
            if r.isCopy { "Archive the Copy of \"\(clip(r.title))\"" }
            else if r.state == .started { r.sessionCount == 1 ? "Roll Back \"\(clip(r.title))\"" : "Roll Back \(r.sessionCount) Sessions" }
            else { r.sessionCount == 1 ? "Restore \"\(clip(r.title))\"" : "Restore \(r.sessionCount) Sessions" }
        case .finish: "Finish an interrupted move?"
        case .copy: "Open a Copy in \(session.copyPlan?.destinationPhrase ?? "")"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold)).lineLimit(2)
            switch session.kind {
            case .move:
                if let plan = session.plan {
                    let from = Set(plan.items.map { store.engine.phrase($0.source.name, account: $0.entry.accountID) })
                    Text("From \(from.count == 1 ? from.first! : "\(from.count) places")  →  To \(plan.destinationPhrase)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .restore(let r):
                if r.isCopy {
                    Text("In \(store.engine.phrase(r.to.name, account: r.toAccountID))").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    let to = Set(r.items.map { store.engine.phrase($0.from.name, account: $0.fromAccountID) })
                    Text("From \(store.engine.phrase(r.to.name, account: r.toAccountID))  →  Back to \(to.count == 1 ? to.first! : "\(to.count) places")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .finish(let r):
                let to = Set(r.items.map { store.engine.phrase($0.from.name, account: $0.fromAccountID) })
                Text("\"\(clip(r.title))\"  ·  \(to.count == 1 ? to.first! : "\(to.count) places")  →  \(store.engine.phrase(r.to.name, account: r.toAccountID))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            case .copy:
                if let plan = session.copyPlan {
                    Text("From \(store.engine.phrase(plan.source.name, account: plan.entry.accountID))  →  To \(plan.destinationPhrase)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Review

    private var rows: [DisplayRow] {
        if let plan = session.plan {
            return plan.rows.map { DisplayRow(id: $0.id, status: $0.status, title: $0.title, detail: $0.detail, affected: $0.affected, orgChoices: $0.orgChoices) }
        }
        if let plan = session.copyPlan {
            return plan.rows.map { DisplayRow(id: $0.id, status: $0.status, title: $0.title, detail: $0.detail, affected: []) }
        }
        return session.restorePlan?.rows.enumerated().map { DisplayRow(id: "\($0.offset)", status: $0.element.status, title: $0.element.title, detail: $0.element.detail, affected: []) } ?? []
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = session.record, session.isFinish {
                Text("Session Mover stopped part-way through this move\(r.step.map { " (\(MoveEngineText.step($0)))" } ?? ""). Finish picks up where it stopped. Roll Back puts every file back as it was.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) { ForEach(rows) { r in
                CheckRowView(row: r, pickOrg: { store.chooseOrg(session, orgID: $0) })
            } }
            if session.isMove {
                Label {
                    Text("History comes along. Conversations live in ~/.claude/projects, which every instance reads. This move doesn't touch them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            }
            if session.isCopy { copyNotes }
            if let plan = session.plan, plan.items.count > 1 { skippedList(plan) }
            if session.isMove || session.isRestore || session.isFinish {
                DisclosureGroup("Show Files", isExpanded: $session.showFiles) { files }
                    .font(.system(size: 12))
            }
            buttons
        }
    }

    private var copyNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Comes along").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Stays behind").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Title, full history").font(.system(size: 12))
                    Text("PR links, branch and worktree, sidebar group").font(.system(size: 12))
                }
            }
            Label {
                Text("The original stays in \(session.copyPlan?.source.name ?? "its copy"). Don't run both at once.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if session.plan?.hasDuplicates == true && !session.replace {
                Button("Replace", role: .destructive) { store.beginReplace(session) }
                    .help("Replace the entry already there. It is backed up first.")
            }
            if session.isMove, session.plan?.blockedByBusyApp == true, case .move(let e, _) = session.kind, e.count == 1 {
                Button("Open a Copy Instead") { store.openCopyInstead(session) }
            }
            Spacer()
            if session.isFinish, let r = session.record {
                if session.restorePlan?.isBlocked == true { Button("Not Now") { store.skipRecovery(r) } }
                Button("Roll Back") { store.beginRestore(r) }
                Button(confirmTitle) { store.confirm(session) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            } else {
                Button("Cancel") { store.moveSession = nil }.keyboardShortcut(.cancelAction)
                if session.replace {
                    Button(confirmTitle, role: .destructive) { store.confirm(session) }
                        .keyboardShortcut(.defaultAction).disabled(!canConfirm)
                } else {
                    Button(confirmTitle) { store.confirm(session) }
                        .keyboardShortcut(.defaultAction).disabled(!canConfirm)
                }
            }
        }
    }

    private var quitsApps: Bool { session.restorePlan?.rows.contains { $0.kind == .apps && $0.status == .warn } == true }

    private var confirmTitle: String {
        switch session.kind {
        case .move: return session.plan?.buttonTitle ?? "Move"
        case .copy: return "Open Copy"
        case .finish: return quitsApps ? "Quit & Finish Move" : "Finish Move"
        case .restore(let r):
            let verb = r.isCopy ? "Archive Copy" : (r.state == .started ? "Roll Back" : "Restore")
            return quitsApps ? "Quit & \(verb)" : verb
        }
    }
    private var canConfirm: Bool {
        if let p = session.plan { return p.canMove }
        if let c = session.copyPlan { return c.canCopy }
        if let r = session.restorePlan { return !r.isBlocked }
        return false
    }

    private func skippedList(_ plan: MovePlan) -> some View {
        Group {
            if !plan.blocked.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plan.blocked) { s in
                        Text("Skipped \"\(s.entry.displayTitle)\": \(s.blocks.first?.title ?? "blocked")")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = session.plan {
                ForEach(plan.movable) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text.mono("from  " + s.entry.fileURL.path)
                        Text.mono("to    " + (s.dstURL?.path ?? "?"))
                    }
                }
                Text.mono("backup " + store.engine.backupsDir.path + "/<move id>")
            } else if let r = session.record {
                ForEach(r.files, id: \.path) { f in Text.mono((f.existed ? "restore  " : "remove   ") + f.path) }
                Text.mono("backup " + store.engine.backupsDir.appendingPathComponent(r.id).path)
            }
        }
        .textSelection(.enabled).padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Progress

    private func stepTitle(_ step: MoveStep) -> String {
        switch step {
        case .quit: return session.appNames.isEmpty ? "Quit apps" : "Quit \(session.appNames)"
        case .reopen: return session.appNames.isEmpty ? "Reopen apps" : "Reopen \(session.appNames)"
        case .moveFiles:
            if session.isCopy { return "Open the copy" }
            if let r = session.record { return r.isCopy ? "Archive the copy" : session.isFinish ? "Finish the move" : r.state == .started ? "Roll back files" : "Restore files" }
            return step.title
        default: return step.title
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summaryLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            ForEach(Array(session.stepList.enumerated()), id: \.element) { index, step in
                StepRow(title: stepTitle(step), state: session.steps[step] ?? .pending,
                        started: session.stepStarted[step], elapsed: session.stepElapsed[step],
                        position: "Step \(index + 1) of \(session.stepList.count)")
            }
            HStack {
                Spacer()
                if session.canStop {
                    Button("Stop") { session.cancel.cancel() }.keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(session.phase == .finished ? "Done" : "Finishing…") { store.moveSession = nil }
                        .disabled(session.phase != .finished)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: session.steps) { old, new in
            // VoiceOver hears each step as it changes (spec section 9).
            for (index, step) in session.stepList.enumerated() where old[step] != new[step] && new[step] != .pending {
                let said = "Step \(index + 1) of \(session.stepList.count), \(stepTitle(step)), \(new[step] == .done ? "done" : "running")"
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: said])
            }
        }
    }

    private var summaryLine: String {
        let warn = rows.filter { $0.status == .warn }.count
        return warn == 0 ? "Checks passed." : "\(warn) warning\(warn == 1 ? "" : "s") read."
    }

    // MARK: Failure

    private func failed(_ message: String, _ log: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: 13, weight: .medium))
            if session.showLog, let log { Text.mono(log).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                if log != nil { Button("Show Log") { session.showLog.toggle() } }
                if let app = session.failedApp { Button("Show \(app.name)") { store.showApp(app) } }
                Button("Close") { store.moveSession = nil }.keyboardShortcut(.cancelAction)
                Button("Try Again") { store.retry(session) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Plain-words versions of a journal step for the "stopped part-way" line.
enum MoveEngineText {
    static func step(_ s: String) -> String {
        switch s {
        case "backup": "stopped after the backup"
        case "writeDestination": "stopped after writing the session file"
        case "group": "stopped after moving its group"
        case "idx": "stopped after the archive list"
        case "sideFiles": "stopped after its side files"
        case "lease": "stopped after the worktree lease"
        case "verify": "stopped after verifying"
        case "deleteSource": "stopped while removing the old file"
        default: "stopped after \(s)"
        }
    }
}

struct CheckRowView: View {
    fileprivate let row: DisplayRow
    var pickOrg: (String) -> Void = { _ in }
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.status.symbol).foregroundStyle(row.status.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let d = row.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !row.orgChoices.isEmpty {
                    Menu("Choose Organization") {
                        ForEach(row.orgChoices) { c in
                            Button("\(c.label) (\(c.entryCount) \(c.entryCount == 1 ? "entry" : "entries"))") { pickOrg(c.orgID) }
                        }
                    }
                    .fixedSize().padding(.top, 2)
                }
                if row.status != .pass, row.affected.count > 1 {
                    ForEach(row.affected, id: \.self) { Text("• \($0)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.status.spoken): \(row.title)\(row.detail.map { " \($0)" } ?? "")")
    }
}

private struct StepRow: View {
    let title: String
    let state: StepProgress
    var started: Date?
    var elapsed: TimeInterval?
    var position = ""

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.small).frame(width: 16, height: 16)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(title).font(.system(size: 13)).foregroundStyle(state == .pending ? .secondary : .primary)
            Spacer()
            switch state {
            case .done:
                if let elapsed { Text(Self.format(elapsed)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
            case .running:
                if let started {
                    TimelineView(.periodic(from: started, by: 0.5)) { ctx in
                        Text(Self.format(ctx.date.timeIntervalSince(started))).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            case .pending: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(position.isEmpty ? "" : position + ", ")\(title), \(state == .done ? "done" : state == .running ? "running" : "waiting")")
    }

    static func format(_ t: TimeInterval) -> String { String(format: "%.1f s", max(0, t)) }
}
