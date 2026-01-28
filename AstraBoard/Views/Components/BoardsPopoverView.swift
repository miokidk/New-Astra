import SwiftUI

struct BoardsPopoverView: View {
    @EnvironmentObject var store: BoardStore
    @State private var renamingBoardId: UUID?
    @State private var renameText: String = ""
    @FocusState private var isRenameFieldFocused: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Boards")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if store.boards.isEmpty {
                        Text("No boards yet.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(store.boards, id: \.id) { board in
                            HStack(spacing: 8) {
                                if renamingBoardId == board.id {
                                    HStack(spacing: 8) {
                                        if board.id == store.currentBoardId {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.accentColor)
                                        } else {
                                            Color.clear.frame(width: 12, height: 12)
                                        }

                                        TextField("Board name", text: $renameText)
                                            .textFieldStyle(.plain)
                                            .focused($isRenameFieldFocused)
                                            .onSubmit { commitRename(board.id) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(board.id == store.currentBoardId
                                                ? Color.accentColor.opacity(0.15)
                                                : Color.clear)
                                    )

                                    Button(action: { commitRename(board.id) }) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Save Name")

                                    Button(action: cancelRename) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Cancel")
                                } else {
                                    Button(action: {
                                        store.switchBoard(id: board.id)
                                        onDismiss()
                                    }) {
                                        HStack(spacing: 8) {
                                            if board.id == store.currentBoardId {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(.accentColor)
                                            } else {
                                                Color.clear.frame(width: 12, height: 12)
                                            }
                                            Text(boardTitle(board))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(board.id == store.currentBoardId
                                                    ? Color.accentColor.opacity(0.15)
                                                    : Color.clear)
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { beginRename(board) }) {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 12, weight: .semibold))
                                            .frame(width: 24, height: 24)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color.primary.opacity(0.08))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Rename Board")

                                    Button(action: {
                                        store.deleteBoard(id: board.id)
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.red)
                                            .frame(width: 24, height: 24)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color.red.opacity(0.12))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete Board")
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            Divider()

            Button(action: {
                store.createBoard()
                onDismiss()
            }) {
                Label("New Board", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { store.refreshBoards() }
    }

    private func beginRename(_ board: BoardMeta) {
        renamingBoardId = board.id
        renameText = boardTitle(board)
        DispatchQueue.main.async { isRenameFieldFocused = true }
    }

    private func commitRename(_ id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameBoard(id: id, title: trimmed)
        renamingBoardId = nil
        renameText = ""
        isRenameFieldFocused = false
    }

    private func cancelRename() {
        renamingBoardId = nil
        renameText = ""
        isRenameFieldFocused = false
    }

    private func boardTitle(_ board: BoardMeta) -> String {
        let trimmed = board.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
