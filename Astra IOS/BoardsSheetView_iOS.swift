import SwiftUI

struct BoardsSheetView: View {
    @EnvironmentObject var store: BoardStore
    @Environment(\.dismiss) private var dismiss

    let onSelectBoard: (UUID) -> Void
    let onCreateBoard: () -> Void
    let onDeleteBoard: (UUID) -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.boards, id: \.id) { board in
                            boardTabView(board)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    onCreateBoard()
                    dismiss()
                }) {
                    Label("New Board", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .navigationTitle("Boards")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { store.refreshBoards() }
        }
        .navigationViewStyle(.stack)
    }

    private func boardTabView(_ board: BoardMeta) -> some View {
        let isActive = board.id == store.currentBoardId
        return HStack(spacing: 8) {
            Button(action: {
                onSelectBoard(board.id)
                dismiss()
            }) {
                Text(boardTitle(board))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isActive ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)

            Button(action: {
                onDeleteBoard(board.id)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete Board")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(isActive ? Color.accentColor : Color(UIColor.secondarySystemBackground))
        )
    }

    private func boardTitle(_ board: BoardMeta) -> String {
        let trimmed = board.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
