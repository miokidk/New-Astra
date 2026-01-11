import SwiftUI

struct ToolPaletteView: View {
    @EnvironmentObject var store: BoardStore
    @State private var showClearConfirm = false

    private var paletteTools: [BoardTool] {
        BoardTool.allCases.filter { $0 != .select }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(paletteTools) { tool in
                Button {
                    if store.currentTool == tool {
                        store.currentTool = .select
                    } else {
                        store.currentTool = tool
                    }
                } label: {
                    Image(systemName: symbol(for: tool))
                        .frame(width: 32, height: 32)
                        .background(store.currentTool == tool ? Color.purple.opacity(0.25) : Color.gray.opacity(0.15))
                        .foregroundColor(.primary)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25), lineWidth: 1))
                        .cornerRadius(8)
                        .help(tool.label)
                }
                .buttonStyle(.plain)
            }

            Button {
                store.togglePanel(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 32, height: 32)
                    .background(store.doc.ui.panels.settings.isOpen ? Color.purple.opacity(0.25) : Color.gray.opacity(0.15))
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25), lineWidth: 1))
                    .cornerRadius(8)
                    .help("Settings")
            }
            .buttonStyle(.plain)

            Button {
                store.togglePanel(.personality)
            } label: {
                Image(systemName: "person.crop.circle")
                    .frame(width: 32, height: 32)
                    .background(store.doc.ui.panels.personality.isOpen ? Color.purple.opacity(0.25) : Color.gray.opacity(0.15))
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25), lineWidth: 1))
                    .cornerRadius(8)
                    .help("Personality")
            }
            .buttonStyle(.plain)

            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.2))
                    .foregroundColor(.red)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.35), lineWidth: 1))
                    .cornerRadius(8)
                    .help("Clear Board")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.8)))
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
        .confirmationDialog("Clear the board?", isPresented: $showClearConfirm) {
            Button("Clear Board", role: .destructive) {
                store.clearBoard()
            }
        }
    }

    private func symbol(for tool: BoardTool) -> String {
        switch tool {
        case .select: return "hand.draw"
        case .text: return "textformat"
        case .image: return "photo"
        case .rect: return "square.on.square"
        case .circle: return "circle"
        case .line: return "pencil.and.outline"
        }
    }
}
