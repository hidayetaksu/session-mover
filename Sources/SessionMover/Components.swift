import SwiftUI
import SessionMoverKit

extension ChipTone {
    var color: Color {
        switch self {
        case .accent: .accentColor
        case .green: .green
        case .orange: .orange
        case .yellow: .yellow
        case .gray, .neutral: .secondary
        case .red: .red
        }
    }
}

extension ChipTone {
    /// Text and glyph colour. In light mode the yellow, orange, green and red system colours are too pale
    /// on their own 14 % fill, so they get darker variants that keep 4.5:1.
    func textColor(dark: Bool) -> Color {
        if dark { return self == .red ? Color(red: 1, green: 0.5, blue: 0.45) : color }
        switch self {
        case .yellow: return Color(red: 0.50, green: 0.36, blue: 0.0)
        case .orange: return Color(red: 0.68, green: 0.29, blue: 0.0)
        case .green: return Color(red: 0.07, green: 0.45, blue: 0.20)
        case .red: return Color(red: 0.76, green: 0.12, blue: 0.10)
        default: return color
        }
    }
}

/// A floating panel's background: material, or the opaque window colour with Reduce Transparency on.
struct PanelBackground<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) } else { shape.fill(.regularMaterial) }
        }
    }
}

extension View {
    func panelBackground<S: Shape>(_ shape: S) -> some View { modifier(PanelBackground(shape: shape)) }
}

struct InstanceTile: View {
    let instance: Instance
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color(hex: instance.accentHex))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: instance.iconName)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct ChipView: View {
    let chip: StateChip
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tone = chip.tone.color
        HStack(spacing: 3) {
            Image(systemName: chip.symbol)
                .font(.system(size: chip == .running ? 6 : 9, weight: .medium))
                .symbolEffect(.pulse, isActive: chip == .busy && !reduceMotion)
            Text(chip.title).monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(chip.tone == .neutral || chip.tone == .gray ? Color.secondary : chip.tone.textColor(dark: scheme == .dark))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tone.opacity(chip.tone == .neutral ? 0.0 : (scheme == .dark ? 0.22 : 0.14)), in: Capsule())
        .overlay { if chip.tone == .neutral || contrast == .increased { Capsule().strokeBorder(tone.opacity(0.6), lineWidth: 1) } }
        .lineLimit(1)
        .fixedSize()
    }
}

struct Banner: View {
    let text: String
    var detail: String?
    var tint: Color = .accentColor
    var symbol = "info.circle.fill"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

extension Text {
    static func mono(_ s: String, size: CGFloat = 11) -> Text {
        Text(s).font(.system(size: size, design: .monospaced))
    }
}
