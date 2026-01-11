# AstraBoard (macOS SwiftUI)

A local-first Freeform-style infinite board built with SwiftUI for macOS (Ventura+). The project lives in `AstraBoard.xcodeproj`.

## Run
1. Open `AstraBoard.xcodeproj` in Xcode (15+ recommended).
2. Select the **AstraBoard** target and run.

## Controls
- **Pan**: drag on the board background (trackpad drag works). 
- **Zoom**: pinch gesture or scroll wheel/trackpad scroll.
- **Select**: click an entry; **Shift+click** to toggle. Drag on empty space for marquee selection.
- **Delete**: `Delete` key or `Board > Delete Selected`.
- **Duplicate**: `Cmd+D`.
- **Z-order**: context menu on an entry has Bring to Front / Send to Back.
- **Move entries**: drag selected entries; resize with corner handles (min 80x60).
- **Tools palette** (top-left buttons):
  - `T`: Text – click to place and edit (returns to select)
  - `I`: Image – click to pick a file; also drop images onto the board (returns to select)
  - `R`: Rect, `C`: Circle – click to drop a default size or drag to draw (returns to select)
  - `L`: Line – click to add points, double-click to finish (returns to select)
- **HUD (purple overlay)**: drag by the left grip; open Chat/Log/Thoughts panels; send chat via HUD input.
- **Floating panels**: draggable/resizable/closable Chat, Log, Thoughts. Thought "View" buttons jump the camera and highlight entries.
- **Dev helper**: “Simulate Model Note” in the HUD drops a model-authored text entry and adds a Thought.

## Persistence
- Autosaves to `~/Library/Application Support/AstraBoard/board.json` (debounced).
- Imported images are copied to `~/Library/Application Support/AstraBoard/Assets/` and referenced by filename.
- Export/Import JSON from the HUD buttons or `Board` command menu.

## Notes
- AI replies are stubbed in `AIService` and run locally.
- Undo/redo is not implemented (MVP uses autosave plus import/export snapshots).
