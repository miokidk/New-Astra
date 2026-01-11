import SwiftUI
import AppKit

struct ToolPaletteView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showClearConfirm = false

    private var paletteTools: [BoardTool] {
        BoardTool.allCases.filter { $0 != .select }
    }
    private var paletteBackground: Color {
        Color(NSColor.windowBackgroundColor).opacity(colorScheme == .dark ? 0.7 : 0.8)
    }
    private var buttonBackground: Color {
        Color(NSColor.controlBackgroundColor).opacity(colorScheme == .dark ? 0.7 : 0.55)
    }
    private var activeButtonBackground: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.25)
    }
    private var borderColor: Color {
        Color(NSColor.separatorColor)
    }
    private var paletteShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12)
    }
    private var destructiveBackground: Color {
        Color.red.opacity(colorScheme == .dark ? 0.3 : 0.2)
    }
    private var destructiveBorder: Color {
        Color.red.opacity(colorScheme == .dark ? 0.5 : 0.35)
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
                        .background(store.currentTool == tool ? activeButtonBackground : buttonBackground)
                        .foregroundColor(.primary)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
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
                    .background(store.doc.ui.panels.settings.isOpen ? activeButtonBackground : buttonBackground)
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .help("Settings")
            }
            .buttonStyle(.plain)

            Button {
                store.togglePanel(.personality)
            } label: {
                Image(systemName: "person.crop.circle")
                    .frame(width: 32, height: 32)
                    .background(store.doc.ui.panels.personality.isOpen ? activeButtonBackground : buttonBackground)
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .help("Personality")
            }
            .buttonStyle(.plain)

            Button {
                store.togglePanel(.memories)
            } label: {
                Image(systemName: "brain")
                    .frame(width: 32, height: 32)
                    .background(store.doc.ui.panels.memories.isOpen ? activeButtonBackground : buttonBackground)
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .help("Memories")
            }
            .buttonStyle(.plain)

            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
                    .background(destructiveBackground)
                    .foregroundColor(.red)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(destructiveBorder, lineWidth: 1))
                    .cornerRadius(8)
                    .help("Clear Board")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(paletteBackground))
        .shadow(color: paletteShadow, radius: 8, x: 0, y: 4)
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
