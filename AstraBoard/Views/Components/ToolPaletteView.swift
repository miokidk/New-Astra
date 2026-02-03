import SwiftUI
import AppKit

struct ToolPaletteView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showClearConfirm = false
    @State private var showBoardsPopover = false

    private var paletteTools: [BoardTool] {
        BoardTool.allCases.filter { $0 != .select && $0 != .rect && $0 != .circle }
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

    private func chooseShape(_ kind: ShapeKind) {
        store.pendingShapeKind = kind
        store.hideToolMenu()
        store.paletteInsertShape(kind: kind, at: store.toolMenuScreenPosition)
    }

    private func shapeSymbol(for kind: ShapeKind) -> String {
        switch kind {
        case .rect: return "rectangle"
        case .circle: return "circle"
        case .triangleUp: return "arrowtriangle.up.fill"
        case .triangleDown: return "arrowtriangle.down.fill"
        case .triangleLeft: return "arrowtriangle.left.fill"
        case .triangleRight: return "arrowtriangle.right.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(paletteTools) { tool in
                Button {
                    switch tool {
                    case .text:
                        store.hideToolMenu()
                        _ = store.paletteInsertText(at: store.toolMenuScreenPosition)
                    case .image:
                        store.hideToolMenu()
                        store.paletteInsertImage(at: store.toolMenuScreenPosition)
                    default:
                        if store.currentTool == tool {
                            store.currentTool = .select
                        } else {
                            store.currentTool = tool
                        }
                        store.hideToolMenu()
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
            Menu {
                Button { chooseShape(.rect) } label: {
                    Label("Rectangle", systemImage: "rectangle")
                }

                Divider()

                Button { chooseShape(.triangleDown) } label: {
                    Label("Triangle (Up/Down)", systemImage: "arrowtriangle.down.fill")
                }

                Button { chooseShape(.triangleRight) } label: {
                    Label("Triangle (Left/Right)", systemImage: "arrowtriangle.right.fill")
                }

                Divider()

                Button { chooseShape(.circle) } label: {
                    Label("Circle", systemImage: "circle")
                }
            } label: {
                Image(systemName: shapeSymbol(for: store.pendingShapeKind))
                    .frame(width: 32, height: 32)
                    .background((store.currentTool == .rect || store.currentTool == .circle) ? activeButtonBackground : buttonBackground)
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .help("Add Shape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            Button {
                store.togglePanel(.settings)
                store.hideToolMenu()
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
                store.togglePanel(.systemInstructions)
                store.hideToolMenu()
            } label: {
                Image(systemName: "terminal")
                    .frame(width: 32, height: 32)
                    .background(store.doc.ui.panels.systemInstructions.isOpen ? activeButtonBackground : buttonBackground)
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .help("System Instructions")
            }
            .buttonStyle(.plain)

            Button {
                store.togglePanel(.memories)
                store.hideToolMenu()
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
                store.togglePanel(.log)
                store.hideToolMenu()
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .frame(width: 32, height: 32)
                    .background(store.doc.ui.panels.log.isOpen ? activeButtonBackground : buttonBackground)
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .help("Log")
            }
            .buttonStyle(.plain)

            Button {
                showBoardsPopover.toggle()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .frame(width: 32, height: 32)
                    .background(showBoardsPopover ? activeButtonBackground : buttonBackground)
                    .foregroundColor(.primary)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    .cornerRadius(8)
                    .help("Boards")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showBoardsPopover, arrowEdge: .bottom) {
                BoardsPopoverView(onDismiss: {
                    showBoardsPopover = false
                    store.hideToolMenu()
                })
                .environmentObject(store)
            }

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
                store.hideToolMenu()
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
