import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Notes Mode

struct WorkspaceModeSwitcher: View {
    @Binding var mode: WorkspaceMode

    var body: some View {
        Menu {
            Button { mode = .canvas } label: { Label("Canvas Mode", systemImage: "square.grid.2x2") }
            Button { mode = .notes }  label: { Label("Notes Mode", systemImage: "doc.text") }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .help("Workspace mode")
    }
}

struct NotesWorkspaceView: View {
    @EnvironmentObject var store: BoardStore
    @State private var expandedStacks: Set<UUID> = []
    @State private var expandedNotebooks: Set<UUID> = []
    @State private var expandedSections: Set<UUID> = []

    private var isSidebarCollapsed: Bool { store.doc.notes.sidebarCollapsed }

    private var sidebarCollapsedBinding: Binding<Bool> {
        Binding(
            get: { store.doc.notes.sidebarCollapsed },
            set: { store.doc.notes.sidebarCollapsed = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarCollapsed.wrappedValue { collapsedSidebar } else { sidebar }
            Divider()
            editor
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func bindingExpanded(_ set: Binding<Set<UUID>>, _ id: UUID) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { isOn in
                if isOn { set.wrappedValue.insert(id) }
                else { set.wrappedValue.remove(id) }
            }
        )
    }

    private var sidebarCollapsed: Binding<Bool> {
        Binding(
            get: { store.doc.notes.sidebarCollapsed },
            set: { store.doc.notes.sidebarCollapsed = $0 }
        )
    }

    private var sidebar: some View {
        NotesSidebarTree(sidebarCollapsed: sidebarCollapsed)
            .frame(width: 260)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
    }

    private var collapsedSidebar: some View {
        VStack {
            Button { sidebarCollapsed.wrappedValue = false } label: {
                chromeIcon("line.3.horizontal")
            }
            .buttonStyle(.plain)
            .padding(.top, 10)

            Spacer()
        }
        .frame(width: 44)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
    }

    private var stackPicker: some View {
        let stacks = store.doc.notes.stacks
        return Group {
            if stacks.isEmpty {
                pill("No Stacks", selected: false)
            } else {
                Menu {
                    ForEach(stacks) { s in Button(s.title) { select(stackID: s.id) } }
                } label: {
                    pill(selectedStack()?.title ?? "Stack", selected: true, showsChevron: true)
                }
                .menuStyle(BorderlessButtonMenuStyle())
            }
        }
    }

    private var notebookPicker: some View {
        let notebooks = selectedStack()?.notebooks ?? []
        return Group {
            if notebooks.isEmpty {
                pill("No Notebooks", selected: false)
            } else {
                Menu {
                    ForEach(notebooks) { nb in Button(nb.title) { select(notebookID: nb.id) } }
                } label: {
                    pill(selectedNotebook()?.title ?? "Notebook", selected: true, showsChevron: true)
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .padding(.leading, 12)
            }
        }
    }

    private var sectionList: some View {
        let sections = selectedNotebook()?.sections ?? []
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { sec in
                Button { select(sectionID: sec.id) } label: {
                    pill(sec.title, selected: store.doc.notes.selection.sectionID == sec.id)
                }
                .buttonStyle(.plain)
                .padding(.leading, 24)
            }
        }
    }

    private var noteList: some View {
        let notes = selectedSection()?.notes ?? []
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(notes) { note in
                Button { select(noteID: note.id) } label: {
                    pill(note.displayTitle,
                        selected: store.doc.notes.selection.noteID == note.id)
                }
                .buttonStyle(.plain)
                .padding(.leading, 36)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                if let note = selectedNote() {
                    Text(metadataString(for: note))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 14)
                        .padding(.top, 10)
                }
            }

            if selectedNote() == nil {
                VStack {
                    Spacer()
                    Text("No note selected").foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Title", text: bindingForSelectedNoteTitle())
                            .font(.system(size: 34, weight: .bold))
                            .textFieldStyle(.plain)

                        TextEditor(text: bindingForSelectedNoteBody())
                            .font(.system(size: 16))
                            .frame(minHeight: 420)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 860, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor).opacity(0.55))
    }

    private func chromeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
    }

    // ---- UI bits ----

    @ViewBuilder
    private func pill(_ text: String, selected: Bool, showsChevron: Bool = false) -> some View {
        HStack(spacing: 8) {
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color(NSColor.controlBackgroundColor).opacity(selected ? 0.95 : 0.75)))
        .overlay(Capsule().stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }

    private func metadataString(for note: NoteItem) -> String {
        let created = Date(timeIntervalSince1970: note.createdAt)
        let edited = Date(timeIntervalSince1970: note.updatedAt)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "Created \(df.string(from: created)) · Edited \(df.string(from: edited))"
    }

    // ---- selection helpers ----

    private func selectedStack() -> NoteStack? {
        guard let id = store.doc.notes.selection.stackID else { return store.doc.notes.stacks.first }
        return store.doc.notes.stacks.first(where: { $0.id == id }) ?? store.doc.notes.stacks.first
    }

    private func selectedNotebook() -> NoteNotebook? {
        guard let stack = selectedStack() else { return nil }
        let notebooks = stack.notebooks
        guard let id = store.doc.notes.selection.notebookID else { return notebooks.first }
        return notebooks.first(where: { $0.id == id }) ?? notebooks.first
    }

    private func selectedSection() -> NoteSection? {
        guard let nb = selectedNotebook() else { return nil }
        let sections = nb.sections
        guard let id = store.doc.notes.selection.sectionID else { return sections.first }
        return sections.first(where: { $0.id == id }) ?? sections.first
    }

    private func selectedNote() -> NoteItem? {
        guard let stack = selectedStack() else { return nil }
        let sel = store.doc.notes.selection

        // If a specific note is selected, find it in the right place.
        if let noteID = sel.noteID {
            // section note
            if let nbID = sel.notebookID, let secID = sel.sectionID,
            let nb = stack.notebooks.first(where: { $0.id == nbID }),
            let sec = nb.sections.first(where: { $0.id == secID }),
            let note = sec.notes.first(where: { $0.id == noteID }) {
                return note
            }

            // notebook root note
            if let nbID = sel.notebookID,
            let nb = stack.notebooks.first(where: { $0.id == nbID }),
            let note = nb.notes.first(where: { $0.id == noteID }) {
                return note
            }

            // stack root note
            if let note = stack.notes.first(where: { $0.id == noteID }) {
                return note
            }

            // fallback (in case selection got out of sync)
            for nb in stack.notebooks {
                if let note = nb.notes.first(where: { $0.id == noteID }) { return note }
                for sec in nb.sections {
                    if let note = sec.notes.first(where: { $0.id == noteID }) { return note }
                }
            }
            return nil
        }

        // No note selected yet → pick a sensible default for the current selection scope.
        if let nbID = sel.notebookID, let secID = sel.sectionID,
        let nb = stack.notebooks.first(where: { $0.id == nbID }),
        let sec = nb.sections.first(where: { $0.id == secID }) {
            return sec.notes.first
        }

        if let nbID = sel.notebookID,
        let nb = stack.notebooks.first(where: { $0.id == nbID }) {
            return nb.notes.first ?? nb.sections.first?.notes.first
        }

        return stack.notes.first ?? stack.notebooks.first?.notes.first ?? stack.notebooks.first?.sections.first?.notes.first
    }

    private func select(stackID: UUID) {
        store.doc.notes.selection.stackID = stackID
        let stack = store.doc.notes.stacks.first(where: { $0.id == stackID })
        let nb = stack?.notebooks.first
        store.doc.notes.selection.notebookID = nb?.id
        let sec = nb?.sections.first
        store.doc.notes.selection.sectionID = sec?.id
        store.doc.notes.selection.noteID = sec?.notes.first?.id
    }

    private func select(notebookID: UUID) {
        store.doc.notes.selection.notebookID = notebookID
        if let nb = selectedStack()?.notebooks.first(where: { $0.id == notebookID }) {
            let sec = nb.sections.first
            store.doc.notes.selection.sectionID = sec?.id
            store.doc.notes.selection.noteID = sec?.notes.first?.id
        }
    }

    private func select(sectionID: UUID) {
        store.doc.notes.selection.sectionID = sectionID
        if let sec = selectedNotebook()?.sections.first(where: { $0.id == sectionID }) {
            store.doc.notes.selection.noteID = sec.notes.first?.id
        }
    }

    private func select(noteID: UUID) {
        store.doc.notes.selection.noteID = noteID
    }

    // ---- bindings / editing ----

    private func bindingForSelectedNoteTitle() -> Binding<String> {
        Binding(
            get: { selectedNote()?.title ?? "" },
            set: { newValue in updateSelectedNote { $0.title = newValue } }
        )
    }

    private func bindingForSelectedNoteBody() -> Binding<String> {
        Binding(
            get: { selectedNote()?.body ?? "" },
            set: { newValue in updateSelectedNote { $0.body = newValue } }
        )
    }

    private func updateSelectedNote(_ mutate: (inout NoteItem) -> Void) {
        guard let sID = store.doc.notes.selection.stackID,
            let noteID = store.doc.notes.selection.noteID else { return }

        guard let sIdx = store.doc.notes.stacks.firstIndex(where: { $0.id == sID }) else { return }

        let nbID = store.doc.notes.selection.notebookID
        let secID = store.doc.notes.selection.sectionID

        // 1) Section note
        if let nbID, let secID {
            guard let nbIdx = store.doc.notes.stacks[sIdx].notebooks.firstIndex(where: { $0.id == nbID }) else { return }
            guard let secIdx = store.doc.notes.stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == secID }) else { return }
            guard let nIdx = store.doc.notes.stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

            var note = store.doc.notes.stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes[nIdx]
            mutate(&note)
            note.updatedAt = Date().timeIntervalSince1970
            store.doc.notes.stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes[nIdx] = note
            store.doc.updatedAt = note.updatedAt
            return
        }

        // 2) Notebook root note
        if let nbID {
            guard let nbIdx = store.doc.notes.stacks[sIdx].notebooks.firstIndex(where: { $0.id == nbID }) else { return }
            guard let nIdx = store.doc.notes.stacks[sIdx].notebooks[nbIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

            var note = store.doc.notes.stacks[sIdx].notebooks[nbIdx].notes[nIdx]
            mutate(&note)
            note.updatedAt = Date().timeIntervalSince1970
            store.doc.notes.stacks[sIdx].notebooks[nbIdx].notes[nIdx] = note
            store.doc.updatedAt = note.updatedAt
            return
        }

        // 3) Stack root note
        guard let nIdx = store.doc.notes.stacks[sIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
        var note = store.doc.notes.stacks[sIdx].notes[nIdx]
        mutate(&note)
        note.updatedAt = Date().timeIntervalSince1970
        store.doc.notes.stacks[sIdx].notes[nIdx] = note
        store.doc.updatedAt = note.updatedAt
    }

    // ---- creation ----

    private func addStack() {
        let now = Date().timeIntervalSince1970
        let note = NoteItem(id: UUID(), title: "", body: "", createdAt: now, updatedAt: now)
        let section = NoteSection(id: UUID(), title: "Section", notes: [note])
        let notebook = NoteNotebook(id: UUID(), title: "Notebook", sections: [section])
        let stack = NoteStack(id: UUID(), title: "New Stack", notebooks: [notebook])
        store.doc.notes.stacks.append(stack)
        store.doc.notes.selection = NotesSelection(stackID: stack.id, notebookID: notebook.id, sectionID: section.id, noteID: note.id)
    }

    private func addNotebook() {
        guard let sID = store.doc.notes.selection.stackID,
              let sIdx = store.doc.notes.stacks.firstIndex(where: { $0.id == sID }) else {
            addStack(); return
        }
        let now = Date().timeIntervalSince1970
        let note = NoteItem(id: UUID(), title: "", body: "", createdAt: now, updatedAt: now)
        let section = NoteSection(id: UUID(), title: "Section", notes: [note])
        let notebook = NoteNotebook(id: UUID(), title: "New Notebook", sections: [section])
        store.doc.notes.stacks[sIdx].notebooks.append(notebook)
        store.doc.notes.selection.notebookID = notebook.id
        store.doc.notes.selection.sectionID = section.id
        store.doc.notes.selection.noteID = note.id
    }

    private func addSection() {
        guard let sID = store.doc.notes.selection.stackID,
              let nbID = store.doc.notes.selection.notebookID,
              let sIdx = store.doc.notes.stacks.firstIndex(where: { $0.id == sID }),
              let nbIdx = store.doc.notes.stacks[sIdx].notebooks.firstIndex(where: { $0.id == nbID }) else {
            addNotebook(); return
        }
        let now = Date().timeIntervalSince1970
        let note = NoteItem(id: UUID(), title: "", body: "", createdAt: now, updatedAt: now)
        let section = NoteSection(id: UUID(), title: "New Section", notes: [note])
        store.doc.notes.stacks[sIdx].notebooks[nbIdx].sections.append(section)
        store.doc.notes.selection.sectionID = section.id
        store.doc.notes.selection.noteID = note.id
    }

    private func addNote() {
        guard let sID = store.doc.notes.selection.stackID,
              let nbID = store.doc.notes.selection.notebookID,
              let secID = store.doc.notes.selection.sectionID,
              let sIdx = store.doc.notes.stacks.firstIndex(where: { $0.id == sID }),
              let nbIdx = store.doc.notes.stacks[sIdx].notebooks.firstIndex(where: { $0.id == nbID }),
              let secIdx = store.doc.notes.stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == secID }) else {
            addSection(); return
        }
        let now = Date().timeIntervalSince1970
        let note = NoteItem(id: UUID(), title: "", body: "", createdAt: now, updatedAt: now)
        store.doc.notes.stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.append(note)
        store.doc.notes.selection.noteID = note.id
    }
}

struct BoardGridView: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let zoom = store.doc.viewport.zoom.cg
                let offsetX = store.doc.viewport.offsetX.cg
                let offsetY = store.doc.viewport.offsetY.cg
                
                // Grid spacing is constant in world coordinates.
                let step: CGFloat = 32
                
                // Spacing in screen coordinates.
                let spacing = step * zoom
                
                // Dot size scales with zoom, but is clamped to a reasonable range.
                let dotSize: CGFloat = min(max(1.5, 3.0 * zoom), 8.0)

                // Calculate visual offset based on pan.
                let offset = CGPoint(
                    x: offsetX.truncatingRemainder(dividingBy: spacing),
                    y: offsetY.truncatingRemainder(dividingBy: spacing)
                )

                // Draw dots
                var path = Path()
                // Don't draw if dots are too dense to avoid performance issues and visual noise.
                if spacing > 3.0 {
                    // Expand the drawing loop slightly outside bounds to ensure edges are covered during rapid pan.
                    for x in stride(from: offset.x - spacing, through: size.width + spacing, by: spacing) {
                        for y in stride(from: offset.y - spacing, through: size.height + spacing, by: spacing) {
                            // Center the dot on the grid point.
                            let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                            path.addEllipse(in: rect)
                        }
                    }
                }
                
                // Fade opacity smoothly when zooming very far out to reduce visual noise.
                let opacity = min(0.5, max(0.1, zoom * 0.4))
                ctx.fill(path, with: .color(Color.secondary.opacity(opacity)))
            }
            .background(ScrollZoomView { dx, dy, location, modifiers in
                store.notePointerLocation(location)
                if modifiers.contains(.option) || modifiers.contains(.command) {
                    // Zoom
                    // Scale factor: dy is usually small (e.g. 0.1 to 5.0).
                    // We map scrolling up (positive) to zoom in (>1) and down to zoom out (<1).
                    let sensitivity: CGFloat = 0.005
                    let scale = 1.0 + (dy * sensitivity)
                    store.applyZoom(delta: scale, focus: location)
                } else {
                    // Pan
                    store.applyPan(translation: CGSize(width: dx, height: dy))
                }
            })
        }
        .allowsHitTesting(true) // Ensure background takes hits
    }
}

struct BoardWorldView: View {
    @EnvironmentObject var store: BoardStore
    @Binding var activeTextEdit: UUID?
    @State private var marqueeStart: CGPoint?
    @State private var lineDraftId: UUID?
    @State private var lineDragStart: CGPoint?
    @State private var lastPan: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeOrShapeDrag())
                    .simultaneousGesture(panGesture())
                    .simultaneousGesture(magnificationGesture())
                    .simultaneousGesture(tapGesture())
                    .simultaneousGesture(clickGesture())

                ForEach(store.doc.zOrder, id: \.self) { id in
                    if let entry = store.doc.entries[id] {
                        EntryContainerView(entry: entry, activeTextEdit: $activeTextEdit)
                            .contextMenu {
                                entryContextMenu(for: entry)
                            }
                    }
                }

                if let marquee = store.marqueeRect {
                    let zoom = store.doc.viewport.zoom.cg
                    let size = CGSize(width: marquee.size.width * zoom,
                                      height: marquee.size.height * zoom)
                    let center = screenPoint(for: marquee.origin + CGSize(width: marquee.width / 2,
                                                                          height: marquee.height / 2))
                    if store.currentTool == .circle {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .background(Circle().fill(Color.accentColor.opacity(0.1)))
                            .frame(width: size.width, height: size.height)
                            .position(center)
                    } else {
                        Rectangle()
                            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .background(Rectangle().fill(Color.accentColor.opacity(0.1)))
                            .frame(width: size.width, height: size.height)
                            .position(center)
                    }
                }
            }
            .background(Color.clear)
            .onChange(of: geo.size) { store.viewportSize = $0 }
            .onChange(of: store.currentTool) { tool in
                if tool != .line {
                    lineDraftId = nil
                    lineDragStart = nil
                }
            }
            .coordinateSpace(name: "board")
        }
    }

    @ViewBuilder
    private func entryContextMenu(for entry: BoardEntry) -> some View {
        // Text editing
        if entry.type == .text {
            Button("Edit Text") {
                store.select(entry.id)
                activeTextEdit = entry.id
                store.beginEditing(entry.id)
            }
        }

        // Shared style editor (supports both text + shapes)
        if entry.type == .shape || entry.type == .text {
            Button("Edit Style…") {
                store.select(entry.id)
                if !store.doc.ui.panels.shapeStyle.isOpen {
                    store.togglePanel(.shapeStyle)
                }
            }
        }

        Divider()

        Button("Duplicate") {
            store.select(entry.id)
            store.duplicateSelected()
        }

        Button("Delete") {
            store.select(entry.id)
            store.deleteSelected()
        }
    }

    private func tapGesture() -> some Gesture {
    SpatialTapGesture(coordinateSpace: .named("MainViewSpace"))
        .onEnded { value in
            guard !store.isDraggingOverlay else { return }
            dismissFocus()

            let screenPoint = value.location
            store.notePointerLocation(screenPoint)

            // Line tool is handled by the drag gesture
            guard store.currentTool != .line else { return }

            store.marqueeRect = nil
            marqueeStart = nil

            switch store.currentTool {
            case .select:
                if let hit = store.topEntryAtScreenPoint(screenPoint) {
                    store.selection = [hit]
                    withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                } else {
                    if store.isToolMenuVisible {
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                    } else {
                        store.selection.removeAll()
                        activeTextEdit = nil
                        withAnimation(.easeOut(duration: 0.12)) {
                            store.showToolMenu(at: screenPoint)
                        }
                    }
                }

            case .text:
                withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                placeText(at: worldPoint(from: screenPoint))

            case .image:
                withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                promptImage(at: worldPoint(from: screenPoint))

            case .rect:
                withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                placeShape(kind: .rect, at: worldPoint(from: screenPoint))

            case .circle:
                withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                placeShape(kind: .circle, at: worldPoint(from: screenPoint))

            case .line:
                break
            }
        }
}

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("MainViewSpace"))
            .onChanged { value in
                guard !store.isDraggingOverlay else { return }
                guard store.currentTool.allowsPanGesture else { return }
                guard store.marqueeRect == nil else { return }
                let delta = CGSize(width: value.translation.width - lastPan.width,
                                   height: value.translation.height - lastPan.height)
                store.notePointerLocation(value.location)
                lastPan = value.translation
            }
            .onEnded { _ in lastPan = .zero }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let delta = scale / lastMagnification
                store.applyZoom(delta: delta, focus: store.lastPointerLocationInViewport)
                lastMagnification = scale
            }
            .onEnded { _ in lastMagnification = 1.0 }
    }

    private func clickGesture() -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("MainViewSpace"))
            .onChanged { value in
                guard store.currentTool == .line else { return }
                guard !store.isDraggingOverlay else { return }
                let startWorld = worldPoint(from: value.startLocation)
                let currentWorld = worldPoint(from: value.location)
                if lineDraftId == nil {
                    lineDragStart = startWorld
                    let id = store.createLineEntry(start: startWorld, end: currentWorld)
                    lineDraftId = id
                    store.selection = [id]
                } else if let id = lineDraftId {
                    store.updateLine(id: id, start: lineDragStart, end: currentWorld, recordUndo: false)
                }
                store.notePointerLocation(value.location)
            }
            .onEnded { value in
                guard store.currentTool == .line else { return }
                dismissFocus()

                let screenPoint = value.location   // NOW in MainViewSpace
                store.marqueeRect = nil
                marqueeStart = nil

                switch store.currentTool {
                case .line:
                    let zoom = max(store.doc.viewport.zoom.cg, 0.001)
                    let defaultLength: CGFloat = 140 / zoom
                    let fallbackStart = worldPoint(from: screenPoint)
                    let fallbackEnd = CGPoint(x: fallbackStart.x + defaultLength, y: fallbackStart.y)

                    let id = lineDraftId ?? store.createLineEntry(start: fallbackStart, end: fallbackEnd)
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance < 4, let start = lineDragStart {
                        let end = CGPoint(x: start.x + defaultLength, y: start.y)
                        store.updateLine(id: id, start: start, end: end, recordUndo: false)
                    }
                    store.selection = [id]
                    store.currentTool = .select
                    lineDraftId = nil
                    lineDragStart = nil

                default:
                    let distance = hypot(value.translation.width, value.translation.height)
                    guard distance < 3 else { return }

                    switch store.currentTool {
                    case .select:
                        if let hit = store.topEntryAtScreenPoint(screenPoint) {
                            store.selection = [hit]
                            withAnimation(.easeOut(duration: 0.12)) {
                                store.hideToolMenu()
                            }
                        } else {
                            if store.isToolMenuVisible {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    store.hideToolMenu()
                                }
                            } else {
                                store.selection.removeAll()
                                activeTextEdit = nil
                                withAnimation(.easeOut(duration: 0.12)) {
                                    store.showToolMenu(at: screenPoint)
                                }
                            }
                }

                    case .text:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        placeText(at: worldPoint(from: screenPoint))

                    case .image:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        promptImage(at: worldPoint(from: screenPoint))

                    case .rect:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        placeShape(kind: .rect, at: worldPoint(from: screenPoint))

                    case .circle:
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                        placeShape(kind: .circle, at: worldPoint(from: screenPoint))

                    case .line:
                        break
                    }
                }
            }
    }

    private func marqueeOrShapeDrag() -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = worldPoint(from: value.startLocation)
                let current = worldPoint(from: value.location)
                marqueeStart = start
                let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: current, size: .zero))
                let marqueeRect = store.currentTool == .circle
                    ? squareRect(from: start, to: current)
                    : rect
                switch store.currentTool {
                case .select, .rect, .circle:
                    store.marqueeRect = marqueeRect
                default:
                    break
                }
                store.notePointerLocation(value.location)
            }
            .onEnded { value in
                let start = worldPoint(from: value.startLocation)
                let end = worldPoint(from: value.location)
                defer {
                    store.marqueeRect = nil
                    marqueeStart = nil
                }
                switch store.currentTool {
                case .select:
                    let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: end, size: .zero))
                    selectEntries(in: rect)
                case .rect:
                    let rect = CGRect(origin: start, size: .zero).union(CGRect(origin: end, size: .zero))
                    let kind: ShapeKind = .rect
                    let id = store.createEntry(type: .shape, frame: rect, data: .shape(kind))
                    store.selection = [id]
                    store.currentTool = .select
                case .circle:
                    let rect = squareRect(from: start, to: end)
                    let kind: ShapeKind = .circle
                    let id = store.createEntry(type: .shape, frame: rect, data: .shape(kind))
                    store.selection = [id]
                    store.currentTool = .select
                default:
                    break
                }
            }
    }

    private func worldPoint(from screen: CGPoint) -> CGPoint {
        store.worldPoint(from: screen)
    }

    private func screenPoint(for world: CGPoint) -> CGPoint {
        store.screenPoint(fromWorld: world)
    }

    private func screenRect(for entry: BoardEntry) -> CGRect {
        let zoom = store.doc.viewport.zoom.cg
        let origin = CGPoint(x: entry.x.cg * zoom + store.doc.viewport.offsetX.cg,
                             y: entry.y.cg * zoom + store.doc.viewport.offsetY.cg)
        let size = CGSize(width: entry.w.cg * zoom, height: entry.h.cg * zoom)
        return CGRect(origin: origin, size: size)
    }

    private func styleButtonOverlay(for entry: BoardEntry) -> some View {
        let rect = screenRect(for: entry)
        let offset: CGFloat = 8
        return ZStack(alignment: .topTrailing) {
            Color.clear.allowsHitTesting(false)
            Button(action: {
                store.togglePanel(.shapeStyle)
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(NSColor.windowBackgroundColor).opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Edit Style")
            .offset(x: offset, y: -offset)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func dismissFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func placeText(at point: CGPoint) {
        let rect = CGRect(x: point.x - 120, y: point.y - 80, width: 240, height: 160)
        let id = store.createEntry(type: .text, frame: rect, data: .text(""))
        store.selection = [id]
        activeTextEdit = id
        store.currentTool = .select
    }

    private func placeShape(kind: ShapeKind, at point: CGPoint) {
        let rect: CGRect
        switch kind {
        case .rect:
            rect = CGRect(x: point.x - 120, y: point.y - 80, width: 240, height: 160)
        case .circle:
            rect = CGRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200)
        }
        let id = store.createEntry(type: .shape, frame: rect, data: .shape(kind))
        store.selection = [id]
        store.currentTool = .select
    }

    private func promptImage(at point: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "gif"]
        panel.allowsMultipleSelection = false
        defer { store.currentTool = .select }
        if panel.runModal() == .OK, let url = panel.url, let ref = store.copyImage(at: url) {
            let rect = imageRect(for: url, centeredAt: point, maxSide: 320)
            let id = store.createEntry(type: .image, frame: rect, data: .image(ref))
            store.selection = [id]
        }
    }

    private func imageRect(for url: URL, centeredAt point: CGPoint, maxSide: CGFloat) -> CGRect {
        if let nsImage = NSImage(contentsOf: url) {
            let size = nsImage.size
            if size.width > 0 && size.height > 0 {
                let aspect = size.width / size.height
                let width: CGFloat
                let height: CGFloat
                if aspect >= 1 {
                    width = maxSide
                    height = maxSide / aspect
                } else {
                    height = maxSide
                    width = maxSide * aspect
                }
                return CGRect(x: point.x - width / 2,
                              y: point.y - height / 2,
                              width: width,
                              height: height)
            }
        }
        return CGRect(x: point.x - maxSide / 2,
                      y: point.y - maxSide / 2,
                      width: maxSide,
                      height: maxSide)
    }

    private func squareRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        guard side > 0 else {
            return CGRect(origin: start, size: .zero)
        }
        let originX = dx < 0 ? start.x - side : start.x
        let originY = dy < 0 ? start.y - side : start.y
        return CGRect(x: originX, y: originY, width: side, height: side)
    }

    private func selectEntries(in rect: CGRect) {
        var hits: Set<UUID> = []
        for (id, entry) in store.doc.entries {
            let entryRect = CGRect(x: entry.x.cg, y: entry.y.cg, width: entry.w.cg, height: entry.h.cg)
            if rect.intersects(entryRect) {
                hits.insert(id)
            }
        }
        store.selection = hits
    }
}

private struct LineBuilderView: View {
    var points: [CGPoint]
    var viewport: Viewport

    var body: some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for p in points.dropFirst() {
                path.addLine(to: p)
            }
        }
        .stroke(Color.purple, lineWidth: 2)
        .scaleEffect(viewport.zoom.cg, anchor: .topLeading)
        .offset(x: viewport.offsetX.cg, y: viewport.offsetY.cg)
    }
}

struct ScrollZoomView: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, CGPoint, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollCaptureView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ScrollCaptureView: NSView {
            var onScroll: ((CGFloat, CGFloat, CGPoint, NSEvent.ModifierFlags) -> Void)?
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                guard window != nil else {
                    monitor = nil
                    return
                }
                // Capture scroll events globally at the window level
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window else { return event }
                    if event.window !== window {
                        return event
                    }

                    // Check for zoom modifiers (Option or Command)
                    let isZoom = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)

                    // If NOT zooming, allow native scrolling for text views and scroll views
                    if !isZoom {
                        let hitView = window.contentView?.hitTest(event.locationInWindow)
                        if let textView = hitView as? NSTextView, textView.isEditable {
                            return event
                        }
                        if hitView?.enclosingScrollView != nil {
                            return event
                        }
                        if let responder = window.firstResponder as? NSView {
                            if let textView = responder as? NSTextView, textView.isEditable {
                                return event
                            }
                            if responder.enclosingScrollView != nil {
                                return event
                            }
                        }
                    }

                    // If we're zooming, process the event regardless of where the mouse is
                    // Convert the window location to our view's coordinate space
                    let location = self.convert(event.locationInWindow, from: nil)
                    self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, location, event.modifierFlags)
                    
                    // Consume the event when zooming to prevent it from being processed elsewhere
                    return nil
                }
            }

            deinit {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
            
            override func scrollWheel(with event: NSEvent) {
                // Fallback handler - but the monitor above should catch most events
                let location = convert(event.locationInWindow, from: nil)
                onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, location, event.modifierFlags)
            }
        }
}

struct NotesSidebarTree: View {
    @EnvironmentObject var store: BoardStore

    @Binding var sidebarCollapsed: Bool

    @State private var expandedStacks: Set<UUID> = []
    @State private var expandedNotebooks: Set<UUID> = []
    @State private var expandedSections: Set<UUID> = []

    // Search UI state
    @State private var isShowingSearch: Bool = false
    @State private var searchQuery: String = ""
    @State private var searchResults: [NoteSearchResult] = []

    // Drag payload is a plain string so we can use UTType.plainText everywhere.
    // Format: fromStack|fromNotebook(optional)|fromSection(optional)|noteID
    private func makeDragString(stackID: UUID, notebookID: UUID?, sectionID: UUID?, noteID: UUID) -> String {
        let nb = notebookID?.uuidString ?? ""
        let sec = sectionID?.uuidString ?? ""
        return "\(stackID.uuidString)|\(nb)|\(sec)|\(noteID.uuidString)"
    }

    private func parseDragString(_ s: String) -> (fromStack: UUID, fromNotebook: UUID?, fromSection: UUID?, noteID: UUID)? {
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        guard let fromStack = UUID(uuidString: parts[0]) else { return nil }
        let fromNotebook = parts[1].isEmpty ? nil : UUID(uuidString: parts[1])
        let fromSection = parts[2].isEmpty ? nil : UUID(uuidString: parts[2])
        guard let noteID = UUID(uuidString: parts[3]) else { return nil }
        return (fromStack, fromNotebook, fromSection, noteID)
    }

    private func handleNoteDrop(
        _ providers: [NSItemProvider],
        toStackID: UUID,
        toNotebookID: UUID?,
        toSectionID: UUID?
    ) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }

        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let s = (object as? NSString) as String? else { return }
            guard let payload = parseDragString(s) else { return }

            DispatchQueue.main.async {
                store.moveNote(
                    fromStackID: payload.fromStack,
                    fromNotebookID: payload.fromNotebook,
                    fromSectionID: payload.fromSection,
                    noteID: payload.noteID,
                    toStackID: toStackID,
                    toNotebookID: toNotebookID,
                    toSectionID: toSectionID
                )

                // Keep the destination visible.
                expandedStacks.insert(toStackID)
                if let toNotebookID { expandedNotebooks.insert(toNotebookID) }
                if let toSectionID { expandedSections.insert(toSectionID) }
            }
        }

        return true
    }

    private func promptRename(kind: String, current: String, onSave: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Rename \(kind)"
        alert.informativeText = "Enter a new name."
        alert.alertStyle = .informational

        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onSave(field.stringValue)
    }

    private func confirmDelete(kind: String, name: String, onDelete: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Delete \(kind)?"
        alert.informativeText = "\"\(name)\" will be permanently deleted."
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDelete()
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.doc.notes.stacks) { stack in
                        DisclosureGroup(
                            isExpanded: bindingExpanded($expandedStacks, stack.id)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                // stack-level notes (NEW)
                                ForEach(stack.notes) { note in
                                    noteRow(
                                        title: note.displayTitle,
                                        indent: 1,
                                        isSelected: isSelected(stack: stack.id, notebook: nil, section: nil, note: note.id)
                                    )
                                    .onTapGesture { selectStackNote(stackID: stack.id, noteID: note.id) }
                                    .onDrag { NSItemProvider(object: makeDragString(stackID: stack.id, notebookID: nil, sectionID: nil, noteID: note.id) as NSString)}
                                    .contextMenu {
                                        Button("Delete Note", role: .destructive) {
                                            confirmDelete(kind: "Note", name: note.displayTitle) {
                                                store.deleteNote(stackID: stack.id, notebookID: nil, sectionID: nil, noteID: note.id)
                                            }
                                        }
                                    }
                                }
                                ForEach(stack.notebooks) { nb in
                                    DisclosureGroup(
                                        isExpanded: bindingExpanded($expandedNotebooks, nb.id)
                                    ) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            // notebook-level notes
                                            ForEach(nb.notes) { note in
                                                noteRow(
                                                    title: note.displayTitle,
                                                    indent: 2,
                                                    isSelected: isSelected(stack: stack.id, notebook: nb.id, section: nil, note: note.id)
                                                )
                                                .onTapGesture { selectNote(stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: note.id) }
                                                .onDrag { NSItemProvider(object: makeDragString(stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: note.id) as NSString) }
                                                .contextMenu {
                                                    Button("Delete Note", role: .destructive) {
                                                        confirmDelete(kind: "Note", name: note.displayTitle) {
                                                            store.deleteNote(stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: note.id)
                                                        }
                                                    }
                                                }
                                            }

                                            // sections
                                            ForEach(nb.sections) { section in
                                                DisclosureGroup(
                                                    isExpanded: bindingExpanded($expandedSections, section.id)
                                                ) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        ForEach(section.notes) { note in
                                                            noteRow(
                                                                title: note.displayTitle,
                                                                indent: 3,
                                                                isSelected: isSelected(stack: stack.id, notebook: nb.id, section: section.id, note: note.id)
                                                            )
                                                            .onTapGesture { selectNote(stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: note.id) }
                                                            .onDrag { NSItemProvider(object: makeDragString(stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: note.id) as NSString)}
                                                            .contextMenu {
                                                                Button("Delete Note", role: .destructive) {
                                                                    confirmDelete(kind: "Note", name: note.displayTitle) {
                                                                        store.deleteNote(stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: note.id)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                } label: {
                                                    folderRow(
                                                        title: section.title,
                                                        indent: 2,
                                                        systemImage: isSelected(stack: stack.id, notebook: nb.id, section: section.id, note: nil)
                                                            ? "bookmark.fill"
                                                            : "bookmark",
                                                        count: section.notes.count,
                                                        isSelected: isSelected(stack: stack.id, notebook: nb.id, section: section.id, note: nil)
                                                    )
                                                    .onTapGesture {
                                                        toggleExpanded(&expandedSections, section.id)
                                                    }
                                                    .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in handleNoteDrop(providers, toStackID: stack.id, toNotebookID: nb.id, toSectionID: section.id) }
                                                    .contextMenu {
                                                        Button("New Note") { store.addNote(stackID: stack.id, notebookID: nb.id, sectionID: section.id) }

                                                        Divider()

                                                        Button("Rename Section") {
                                                            promptRename(kind: "Section", current: section.title) { newTitle in
                                                                store.renameSection(stackID: stack.id, notebookID: nb.id, sectionID: section.id, title: newTitle)
                                                            }
                                                        }

                                                        Button("Delete Section", role: .destructive) {
                                                            confirmDelete(kind: "Section", name: section.title) {
                                                                expandedSections.remove(section.id)
                                                                store.deleteSection(stackID: stack.id, notebookID: nb.id, sectionID: section.id)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.leading, 14)
                                    } label: {
                                        folderRow(
                                            title: nb.title,
                                            indent: 1,
                                            systemImage: isSelected(stack: stack.id, notebook: nb.id, section: nil, note: nil)
                                                ? "book.closed.fill"
                                                : "book.closed",
                                            count: notebookNoteCount(nb),
                                            isSelected: isSelected(stack: stack.id, notebook: nb.id, section: nil, note: nil)
                                        )
                                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in handleNoteDrop(providers, toStackID: stack.id, toNotebookID: nb.id, toSectionID: nil) }
                                        .contextMenu {
                                            Button("New Section") { store.addSection(stackID: stack.id, notebookID: nb.id) }
                                            Button("New Note") { store.addNote(stackID: stack.id, notebookID: nb.id, sectionID: nil) }

                                            Divider()

                                            Button("Rename Notebook") {
                                                promptRename(kind: "Notebook", current: nb.title) { newTitle in
                                                    store.renameNotebook(stackID: stack.id, notebookID: nb.id, title: newTitle)
                                                }
                                            }

                                            Button("Delete Notebook", role: .destructive) {
                                                confirmDelete(kind: "Notebook", name: nb.title) {
                                                    expandedNotebooks.remove(nb.id)
                                                    for sec in nb.sections { expandedSections.remove(sec.id) }
                                                    store.deleteNotebook(stackID: stack.id, notebookID: nb.id)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 14)
                        } label: {
                            folderRow(
                                title: stack.title,
                                indent: 0,
                                systemImage: isSelected(stack: stack.id, notebook: nil, section: nil, note: nil)
                                    ? "square.stack.3d.up.fill"
                                    : "square.stack.3d.up",
                                count: stackNoteCount(stack),
                                isSelected: isSelected(stack: stack.id, notebook: nil, section: nil, note: nil)
                            )
                            .onTapGesture {
                                toggleExpanded(&expandedStacks, stack.id)
                            }
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in handleNoteDrop(providers, toStackID: stack.id, toNotebookID: nil, toSectionID: nil) }
                            .contextMenu {
                                Button("New Note") { store.addNote(stackID: stack.id, notebookID: nil, sectionID: nil) }
                                Button("New Notebook") { store.addNotebook(stackID: stack.id) }

                                if stack.id != store.doc.notes.quickNotesStackID {
                                    Divider()

                                    Button("Rename Stack") {
                                        promptRename(kind: "Stack", current: stack.title) { newTitle in
                                            store.renameStack(id: stack.id, title: newTitle)
                                        }
                                    }

                                    Button("Delete Stack", role: .destructive) {
                                        confirmDelete(kind: "Stack", name: stack.title) {
                                            expandedStacks.remove(stack.id)
                                            for nb in stack.notebooks {
                                                expandedNotebooks.remove(nb.id)
                                                for sec in nb.sections { expandedSections.remove(sec.id) }
                                            }
                                            store.deleteStack(id: stack.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .onAppear {
            // Apple Notes vibe: stacks shown, but not necessarily expanded.
            // If you want them expanded by default, uncomment:
            // expandedStacks = Set(store.doc.notes.stacks.map(\.id))
            if !searchQuery.isEmpty {
                performSearch()
            }
        }
    }

    // MARK: Header (fixes your layout + removes the mystery button)

    private var header: some View {
        HStack(spacing: 10) {
            WorkspaceModeSwitcher(mode: Binding(
                get: { store.doc.ui.workspaceMode },
                set: { store.doc.ui.workspaceMode = $0 }
            ))

            Spacer()

            Button {
                isShowingSearch.toggle()
                if isShowingSearch {
                    performSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingSearch, arrowEdge: .bottom) {
                NotesSearchView(
                    query: $searchQuery,
                    results: searchResults,
                    onSubmit: { performSearch() },
                    onSelect: { result in
                        selectNoteByID(result.noteID)
                        isShowingSearch = false
                    }
                )
                .environmentObject(store)
            }

            Menu {
                Button("Add Stack") { store.addStack() }
                Button("Quick Note") { store.addQuickNote() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)

            Button { sidebarCollapsed = true } label: {
                Image(systemName: "line.3.horizontal")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
    }

    // MARK: Rows

    private func folderRow(title: String, indent: Int, systemImage: String, count: Int, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .regular))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(indent) * 14)
        .background(isSelected ? Color(NSColor.selectedContentBackgroundColor).opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func noteRow(title: String, indent: Int, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: .regular))
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(indent) * 14)
        .background(isSelected ? Color(NSColor.selectedContentBackgroundColor).opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    // MARK: Selection helpers (adjust to match your NotesSelection)

    private func isSelected(stack: UUID?, notebook: UUID?, section: UUID?, note: UUID?) -> Bool {
        let sel = store.doc.notes.selection
        return sel.stackID == stack &&
            sel.notebookID == notebook &&
            sel.sectionID == section &&
            sel.noteID == note
    }

    private func selectNote(stackID: UUID, notebookID: UUID, sectionID: UUID?, noteID: UUID) {
        store.doc.notes.selection.stackID = stackID
        store.doc.notes.selection.notebookID = notebookID
        store.doc.notes.selection.sectionID = sectionID
        store.doc.notes.selection.noteID = noteID

        expandedStacks.insert(stackID)
        expandedNotebooks.insert(notebookID)
        if let sectionID { expandedSections.insert(sectionID) }
    }

    private func selectStackNote(stackID: UUID, noteID: UUID) {
        store.doc.notes.selection.stackID = stackID
        store.doc.notes.selection.notebookID = nil
        store.doc.notes.selection.sectionID = nil
        store.doc.notes.selection.noteID = noteID
        expandedStacks.insert(stackID)
    }

    /// Selects a note anywhere in the workspace and ensures its containers are expanded.
    private func selectNoteByID(_ noteID: UUID) {
        for stack in store.doc.notes.stacks {
            // Stack-level note
            if stack.notes.contains(where: { $0.id == noteID }) {
                selectStackNote(stackID: stack.id, noteID: noteID)
                return
            }

            // Notebook + section notes
            for notebook in stack.notebooks {
                if notebook.notes.contains(where: { $0.id == noteID }) {
                    selectNote(stackID: stack.id, notebookID: notebook.id, sectionID: nil, noteID: noteID)
                    return
                }
                for section in notebook.sections {
                    if section.notes.contains(where: { $0.id == noteID }) {
                        selectNote(stackID: stack.id, notebookID: notebook.id, sectionID: section.id, noteID: noteID)
                        return
                    }
                }
            }
        }
    }

    // MARK: Counts

    private func notebookNoteCount(_ nb: NoteNotebook) -> Int {
        nb.notes.count + nb.sections.reduce(0) { $0 + $1.notes.count }
    }

    private func stackNoteCount(_ stack: NoteStack) -> Int {
        stack.notes.count + stack.notebooks.reduce(0) { $0 + notebookNoteCount($1) }
    }

    // MARK: Search helpers

    private func performSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        let queryLower = trimmed.lowercased()
        var results: [NoteSearchResult] = []

        for stack in store.doc.notes.stacks {
            let stackPath = "Stack: \(stack.title)"

            // Stack-level notes
            for note in stack.notes {
                if let hit = score(note: note, path: stackPath, queryLower: queryLower, queryOriginal: trimmed) {
                    results.append(hit)
                }
            }

            // Notebook + section notes
            for notebook in stack.notebooks {
                let notebookPath = "\(stackPath) > Notebook: \(notebook.title)"

                for note in notebook.notes {
                    if let hit = score(note: note, path: notebookPath, queryLower: queryLower, queryOriginal: trimmed) {
                        results.append(hit)
                    }
                }

                for section in notebook.sections {
                    let sectionPath = "\(notebookPath) > Section: \(section.title)"
                    for note in section.notes {
                        if let hit = score(note: note, path: sectionPath, queryLower: queryLower, queryOriginal: trimmed) {
                            results.append(hit)
                        }
                    }
                }
            }
        }

        results.sort { $0.score > $1.score }
        searchResults = Array(results.prefix(50))
    }

    private func score(note: NoteItem, path: String, queryLower: String, queryOriginal: String) -> NoteSearchResult? {
        let titleLower = note.displayTitle.lowercased()
        let bodyLower = note.body.lowercased()
        let pathLower = path.lowercased()

        var score = 0
        if titleLower.contains(queryLower) { score += 10 }
        if pathLower.contains(queryLower) { score += 3 }
        if bodyLower.contains(queryLower) { score += 1 }

        guard score > 0 else { return nil }

        let body = note.body
        let snippet: String
        if let range = body.range(of: queryOriginal, options: .caseInsensitive) {
            let startOffset = body.distance(from: body.startIndex, to: range.lowerBound)
            let endOffset = body.distance(from: body.startIndex, to: range.upperBound)
            let window = 40
            let start = max(0, startOffset - window)
            let end = min(body.count, endOffset + window)
            let startIndex = body.index(body.startIndex, offsetBy: start)
            let endIndex = body.index(body.startIndex, offsetBy: end)
            let slice = body[startIndex..<endIndex]
            snippet = (start > 0 ? "…" : "") + slice + (end < body.count ? "…" : "")
        } else {
            snippet = String(body.prefix(80))
        }

        let title = note.displayTitle.isEmpty ? "Untitled" : note.displayTitle

        return NoteSearchResult(
            noteID: note.id,
            title: title,
            snippet: snippet,
            path: path,
            score: score
        )
    }

    // MARK: Expand toggle

    private func toggleExpanded(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func bindingExpanded(_ set: Binding<Set<UUID>>, _ id: UUID) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { isOn in
                if isOn { set.wrappedValue.insert(id) }
                else { set.wrappedValue.remove(id) }
            }
        )
    }

    // MARK: Create ops (wire these to your existing functions)

    private func createStack() {
        store.addStack(title: "New Stack") // adjust signature if needed
    }

    private func createNotebook(stackID: UUID) {
        store.addNotebook(stackID: stackID, title: "New Notebook")
    }

    private func createSection(stackID: UUID, notebookID: UUID) {
        store.addSection(stackID: stackID, notebookID: notebookID, title: "New Section")
        expandedStacks.insert(stackID)
        expandedNotebooks.insert(notebookID)
    }

    private func createNote(stackID: UUID, notebookID: UUID, sectionID: UUID?) {
        store.addNote(stackID: stackID, notebookID: notebookID, sectionID: sectionID, title: "New Note")
        expandedStacks.insert(stackID)
        expandedNotebooks.insert(notebookID)
        if let sectionID { expandedSections.insert(sectionID) }
    }

    private func createQuickNote() {
        store.addQuickNote()
    }
}

// MARK: - Notes search popover

fileprivate struct NoteSearchResult: Identifiable {
    let noteID: UUID
    let title: String
    let snippet: String
    let path: String
    let score: Int

    var id: UUID { noteID }
}

private struct NotesSearchView: View {
    @EnvironmentObject var store: BoardStore

    @Binding var query: String
    var results: [NoteSearchResult]
    var onSubmit: () -> Void
    var onSelect: (NoteSearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search notes", text: $query)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onChange(of: query) { _ in
                    onSubmit()
                }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Type to search across all stacks, notebooks, sections, and notes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else if results.isEmpty {
                Text("No matching notes.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(results) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.title)
                            .font(.headline)
                        Text(hit.snippet)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Text(hit.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(hit)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420,
               minHeight: 220, idealHeight: 320, maxHeight: 420)
    }
}
