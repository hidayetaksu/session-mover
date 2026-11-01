import SwiftUI
import UniformTypeIdentifiers
import SessionMoverKit

/// Private payload type: only Session Mover's own rows can be dropped on its sidebar.
let sessionDragType = UTType(importedAs: "ai.gosmart.sessionmover.session")

func sessionDragProvider() -> NSItemProvider {
    let p = NSItemProvider()
    p.registerDataRepresentation(forTypeIdentifier: sessionDragType.identifier, visibility: .ownProcess) { done in
        done(Data("session".utf8), nil)
        return nil
    }
    return p
}

struct SessionDropDelegate: DropDelegate {
    let store: AppStore
    let target: Scope

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [sessionDragType]) && !store.dragRowIDs.isEmpty }
    func dropEntered(info: DropInfo) { store.dropEntered(target) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        store.updateModifier(for: target)
        return DropProposal(operation: store.dropOperation(target))
    }
    func dropExited(info: DropInfo) { store.dropExited(target) }
    func performDrop(info: DropInfo) -> Bool { store.performDrop(target) }
}

/// A sidebar row that accepts dragged sessions (section 4): accent fill and ring when valid,
/// dimmed with a `nosign` glyph when not. An instance row also rings its signed-in account row.
struct SessionDropTarget: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast
    let target: Scope
    /// For an account row: the instance whose signed-in account this is.
    var signedInOf: String?

    private var isIndirect: Bool {
        guard let i = signedInOf, case .instance(let t)? = store.dropTarget, t == i else { return false }
        return store.dropOperation(.instance(t)) == .move
    }

    func body(content: Content) -> some View {
        let active = store.dropTarget == target
        let refused = active && store.dropOperation(target) == .forbidden
        let indirect = isIndirect
        return content
            .background {
                if active && !refused { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.2)) }
            }
            .overlay {
                if (active && !refused) || indirect {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: contrast == .increased ? 2 : 1, dash: active && store.optionDown ? [4, 3] : []))
                }
            }
            .opacity(refused ? 0.4 : 1)
            .overlay(alignment: .trailing) {
                if refused { Image(systemName: "nosign").foregroundStyle(.secondary).padding(.trailing, 4) }
            }
            .onDrop(of: [sessionDragType], delegate: SessionDropDelegate(store: store, target: target))
    }
}

extension View {
    func sessionDropTarget(_ target: Scope, signedInOf: String? = nil) -> some View {
        modifier(SessionDropTarget(target: target, signedInOf: signedInOf))
    }
}

/// 280 pt capsule: instance tile, title, line 2. Several sessions add a count badge.
struct DragPreview: View {
    @Environment(AppStore.self) private var store
    let entry: SessionEntry

    var body: some View {
        let n = store.selection.contains(entry.rowID) ? max(store.selection.count, 1) : 1
        HStack(spacing: 8) {
            if let i = store.library.instance(entry.instanceID) { InstanceTile(instance: i, size: 20) }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(n > 1 ? "\(n) sessions" : (entry.folderName ?? "No folder")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if n > 1 {
                Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor, in: Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: 280)
        .panelBackground(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}

/// The cursor badge: a label that follows the target under the drag.
struct DropBadgeView: View {
    let text: String
    let refused: Bool
    var body: some View {
        HStack(spacing: 5) {
            if refused { Image(systemName: "nosign") }
            Text(text).lineLimit(2)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .panelBackground(Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .accessibilityLabel(refused ? "Can't drop here. \(text)" : "Drop to \(text)")
    }
}
