import DremCore
import SwiftUI

extension AgentAttention {
    var islandSymbol: String { self == .permission ? "lock.fill" : "questionmark.bubble.fill" }
}

extension AgentActivityDetail.Action {
    /// Presentation only: never guess a shell command from a generic tool call.
    var islandSymbol: String {
        switch self {
        case .working: return "sparkles"
        case .reading: return "doc.text.magnifyingglass"
        case .editing: return "square.and.pencil"
        case .tool: return "wrench.and.screwdriver"
        case .compacting: return "arrow.down.right.and.arrow.up.left"
        }
    }
}

/// The same quiet, baseline-aligned action row at every island density.
/// Icons are static: existing activity events are the only update source.
struct IslandActionLabel: View {
    let action: AgentActivityDetail.Action
    let title: String
    let tint: Color
    var fontSize: CGFloat = 11
    var lineLimit: Int? = 1
    var attention: AgentAttention? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: attention?.islandSymbol ?? action.islandSymbol)
                .font(.system(size: fontSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(attention == nil ? tint : .orange)
                .frame(width: fontSize + 3)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: fontSize))
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
