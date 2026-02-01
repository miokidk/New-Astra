import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Notes Mode

struct WorkspaceModeSwitcher: View {
    @Binding var mode: WorkspaceMode

    var body: some View {
        Menu {
            Button { mode = .canvas } label: { Label("Canvas", systemImage: "square.grid.2x2") }
            Button { mode = .notes }  label: { Label("Notes", systemImage: "text.page") }
        } label: {
            Image(systemName: mode == .canvas ? "square.grid.2x2" : "text.page")
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
        VStack(spacing: 10) {
            WorkspaceModeSwitcher(mode: Binding(
                get: { store.doc.ui.workspaceMode },
                set: { store.doc.ui.workspaceMode = $0 }
            ))
            .padding(.top, 10)

            Button { sidebarCollapsed.wrappedValue = false } label: {
                chromeIcon("line.3.horizontal")
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(width: 44)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
    }

    private var stackPicker: some View {
        let areas = store.doc.notes.areas
        return Group {
            if areas.isEmpty {
                pill("No Areas", selected: false)
            } else {
                Menu {
                    ForEach(areas) { area in Button(area.title) { select(areaID: area.id) } }
                } label: {
                    pill(selectedArea()?.title ?? "Area", selected: true, showsChevron: true)
                }
                .menuStyle(BorderlessButtonMenuStyle())
            }
        }
    }

    private var notebookPicker: some View {
        let notebooks = selectedNotebookContainer() ?? []
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
                if let note = selectedNote(),
                   let parts = notePathParts(noteID: note.id) {
                    notePathView(parts)
                        .padding(.leading, 14)
                        .padding(.top, 10)
                }

                Spacer()

                if let note = selectedNote() {
                    Text(metadataString(for: note))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 14)
                        .padding(.top, 10)
                }
            }

            if let note = selectedNote() {
                if note.isLocked && !store.isNoteUnlockedInSession(note.id) {
                    VStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.secondary)

                            Text("This note is locked")
                                .foregroundColor(.secondary)

                            Button("Unlock with Touch ID…") {
                                Task { _ = await store.ensureUnlockedForViewing(noteID: note.id) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Title", text: bindingForSelectedNoteTitle())
                                .font(.system(size: 34, weight: .bold))
                                .textFieldStyle(.plain)

                            NoteBodyTextView(
                                text: bindingForSelectedNoteBody(),
                                store: store,
                                font: NSFont.systemFont(ofSize: 16),
                                textColor: NSColor.labelColor
                            )
                            .frame(minHeight: 420)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 860, alignment: .leading)
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("No note selected").foregroundColor(.secondary)
                    Spacer()
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

    private struct NotePathPart: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
    }

    private func notePathParts(noteID: UUID) -> [NotePathPart]? {
        func trimmed(_ value: String) -> String? {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        for area in store.doc.notes.areas {
            if area.notes.contains(where: { $0.id == noteID }) {
                return trimmed(area.title).map { [NotePathPart(title: $0, systemImage: "rectangle.3.group")] }
            }

            for notebook in area.notebooks {
                if notebook.notes.contains(where: { $0.id == noteID }) {
                    guard let areaTitle = trimmed(area.title),
                          let notebookTitle = trimmed(notebook.title) else { return nil }
                    return [
                        NotePathPart(title: areaTitle, systemImage: "rectangle.3.group"),
                        NotePathPart(title: notebookTitle, systemImage: "book.closed")
                    ]
                }
                for section in notebook.sections where section.notes.contains(where: { $0.id == noteID }) {
                    guard let areaTitle = trimmed(area.title),
                          let notebookTitle = trimmed(notebook.title),
                          let sectionTitle = trimmed(section.title) else { return nil }
                    return [
                        NotePathPart(title: areaTitle, systemImage: "rectangle.3.group"),
                        NotePathPart(title: notebookTitle, systemImage: "book.closed"),
                        NotePathPart(title: sectionTitle, systemImage: "bookmark")
                    ]
                }
            }

            for stack in area.stacks {
                if stack.notes.contains(where: { $0.id == noteID }) {
                    guard let areaTitle = trimmed(area.title),
                          let stackTitle = trimmed(stack.title) else { return nil }
                    return [
                        NotePathPart(title: areaTitle, systemImage: "rectangle.3.group"),
                        NotePathPart(title: stackTitle, systemImage: "square.stack.3d.up")
                    ]
                }
                for notebook in stack.notebooks {
                    if notebook.notes.contains(where: { $0.id == noteID }) {
                        guard let areaTitle = trimmed(area.title),
                              let stackTitle = trimmed(stack.title),
                              let notebookTitle = trimmed(notebook.title) else { return nil }
                        return [
                            NotePathPart(title: areaTitle, systemImage: "rectangle.3.group"),
                            NotePathPart(title: stackTitle, systemImage: "square.stack.3d.up"),
                            NotePathPart(title: notebookTitle, systemImage: "book.closed")
                        ]
                    }
                    for section in notebook.sections where section.notes.contains(where: { $0.id == noteID }) {
                        guard let areaTitle = trimmed(area.title),
                              let stackTitle = trimmed(stack.title),
                              let notebookTitle = trimmed(notebook.title),
                              let sectionTitle = trimmed(section.title) else { return nil }
                        return [
                            NotePathPart(title: areaTitle, systemImage: "rectangle.3.group"),
                            NotePathPart(title: stackTitle, systemImage: "square.stack.3d.up"),
                            NotePathPart(title: notebookTitle, systemImage: "book.closed"),
                            NotePathPart(title: sectionTitle, systemImage: "bookmark")
                        ]
                    }
                }
            }
        }

        return nil
    }

    private func notePathView(_ parts: [NotePathPart]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                HStack(spacing: 4) {
                    Image(systemName: part.systemImage)
                    Text(part.title)
                }
                if index < parts.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    // ---- selection helpers ----

    private func selectedArea() -> NoteArea? {
        guard let id = store.doc.notes.selection.areaID else { return store.doc.notes.areas.first }
        return store.doc.notes.areas.first(where: { $0.id == id }) ?? store.doc.notes.areas.first
    }

    private func selectedStack() -> NoteStack? {
        guard let area = selectedArea() else { return nil }
        guard let id = store.doc.notes.selection.stackID else { return area.stacks.first }
        return area.stacks.first(where: { $0.id == id }) ?? area.stacks.first
    }

    private func selectedNotebookContainer() -> [NoteNotebook]? {
        if store.doc.notes.selection.stackID != nil {
            return selectedStack()?.notebooks
        }
        return selectedArea()?.notebooks
    }

    private func selectedNotebook() -> NoteNotebook? {
        guard let notebooks = selectedNotebookContainer() else { return nil }
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
        guard let area = selectedArea() else { return nil }
        let sel = store.doc.notes.selection

        let stack = sel.stackID.flatMap { id in
            area.stacks.first(where: { $0.id == id })
        }

        func noteInNotebook(_ nb: NoteNotebook, noteID: UUID) -> NoteItem? {
            if let note = nb.notes.first(where: { $0.id == noteID }) { return note }
            for sec in nb.sections {
                if let note = sec.notes.first(where: { $0.id == noteID }) { return note }
            }
            return nil
        }

        func firstNoteInNotebook(_ nb: NoteNotebook) -> NoteItem? {
            nb.notes.first ?? nb.sections.first?.notes.first
        }

        // If a specific note is selected, find it in the right place.
        if let noteID = sel.noteID {
            if let stack {
                // section note (stack)
                if let nbID = sel.notebookID, let secID = sel.sectionID,
                   let nb = stack.notebooks.first(where: { $0.id == nbID }),
                   let sec = nb.sections.first(where: { $0.id == secID }),
                   let note = sec.notes.first(where: { $0.id == noteID }) {
                    return note
                }

                // notebook root note (stack)
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
                    if let note = noteInNotebook(nb, noteID: noteID) { return note }
                }
                return nil
            } else {
                // section note (area)
                if let nbID = sel.notebookID, let secID = sel.sectionID,
                   let nb = area.notebooks.first(where: { $0.id == nbID }),
                   let sec = nb.sections.first(where: { $0.id == secID }),
                   let note = sec.notes.first(where: { $0.id == noteID }) {
                    return note
                }

                // notebook root note (area)
                if let nbID = sel.notebookID,
                   let nb = area.notebooks.first(where: { $0.id == nbID }),
                   let note = nb.notes.first(where: { $0.id == noteID }) {
                    return note
                }

                // area root note
                if let note = area.notes.first(where: { $0.id == noteID }) {
                    return note
                }

                // fallback (in case selection got out of sync)
                for nb in area.notebooks {
                    if let note = noteInNotebook(nb, noteID: noteID) { return note }
                }
                return nil
            }
        }

        // No note selected yet → pick a sensible default for the current selection scope.
        if let stack {
            if let nbID = sel.notebookID, let secID = sel.sectionID,
               let nb = stack.notebooks.first(where: { $0.id == nbID }),
               let sec = nb.sections.first(where: { $0.id == secID }) {
                return sec.notes.first
            }

            if let nbID = sel.notebookID,
               let nb = stack.notebooks.first(where: { $0.id == nbID }) {
                return firstNoteInNotebook(nb)
            }

            return stack.notes.first ?? stack.notebooks.first.flatMap { firstNoteInNotebook($0) }
        }

        if let nbID = sel.notebookID, let secID = sel.sectionID,
           let nb = area.notebooks.first(where: { $0.id == nbID }),
           let sec = nb.sections.first(where: { $0.id == secID }) {
            return sec.notes.first
        }

        if let nbID = sel.notebookID,
           let nb = area.notebooks.first(where: { $0.id == nbID }) {
            return firstNoteInNotebook(nb)
        }

        return area.notes.first
            ?? area.notebooks.first.flatMap { firstNoteInNotebook($0) }
            ?? area.stacks.first?.notes.first
            ?? area.stacks.first.flatMap { $0.notebooks.first.flatMap { firstNoteInNotebook($0) } }
    }

    private func select(areaID: UUID) {
        store.doc.notes.selection.areaID = areaID
        store.doc.notes.selection.stackID = nil
        store.doc.notes.selection.notebookID = nil
        store.doc.notes.selection.sectionID = nil
        store.doc.notes.selection.noteID = nil
    }

    private func select(notebookID: UUID) {
        store.doc.notes.selection.notebookID = notebookID
        store.doc.notes.selection.sectionID = nil
        store.doc.notes.selection.noteID = nil

        if let notebooks = selectedNotebookContainer(),
           let nb = notebooks.first(where: { $0.id == notebookID }) {
            let sec = nb.sections.first
            store.doc.notes.selection.sectionID = sec?.id
            store.doc.notes.selection.noteID = sec?.notes.first?.id ?? nb.notes.first?.id
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
            set: { newValue in
                let clamped = String(newValue.prefix(NoteItem.maxTitleLength))
                updateSelectedNote { $0.title = clamped }
            }
        )
    }

    private func bindingForSelectedNoteBody() -> Binding<String> {
        Binding(
            get: { selectedNote()?.body ?? "" },
            set: { newValue in updateSelectedNote { $0.body = newValue } }
        )
    }

    private func updateSelectedNote(_ mutate: (inout NoteItem) -> Void) {
        guard let areaID = store.doc.notes.selection.areaID,
              let noteID = store.doc.notes.selection.noteID else { return }
        if store.isNoteLocked(noteID) && !store.isNoteUnlockedInSession(noteID) {
            return
        }

        guard let aIdx = store.doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        let stackID = store.doc.notes.selection.stackID
        let nbID = store.doc.notes.selection.notebookID
        let secID = store.doc.notes.selection.sectionID

        if let stackID {
            guard let sIdx = store.doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }

            // 1) Section note (stack)
            if let nbID, let secID {
                guard let nbIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == nbID }) else { return }
                guard let secIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == secID }) else { return }
                guard let nIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

                var note = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes[nIdx]
                mutate(&note)
                note.updatedAt = Date().timeIntervalSince1970
                store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes[nIdx] = note
                store.doc.updatedAt = note.updatedAt
                return
            }

            // 2) Notebook root note (stack)
            if let nbID {
                guard let nbIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == nbID }) else { return }
                guard let nIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

                var note = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes[nIdx]
                mutate(&note)
                note.updatedAt = Date().timeIntervalSince1970
                store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes[nIdx] = note
                store.doc.updatedAt = note.updatedAt
                return
            }

            // 3) Stack root note
            guard let nIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
            var note = store.doc.notes.areas[aIdx].stacks[sIdx].notes[nIdx]
            mutate(&note)
            note.updatedAt = Date().timeIntervalSince1970
            store.doc.notes.areas[aIdx].stacks[sIdx].notes[nIdx] = note
            store.doc.updatedAt = note.updatedAt
            return
        }

        // Area-level notes
        if let nbID, let secID {
            guard let nbIdx = store.doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == nbID }) else { return }
            guard let secIdx = store.doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == secID }) else { return }
            guard let nIdx = store.doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

            var note = store.doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes[nIdx]
            mutate(&note)
            note.updatedAt = Date().timeIntervalSince1970
            store.doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes[nIdx] = note
            store.doc.updatedAt = note.updatedAt
            return
        }

        if let nbID {
            guard let nbIdx = store.doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == nbID }) else { return }
            guard let nIdx = store.doc.notes.areas[aIdx].notebooks[nbIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

            var note = store.doc.notes.areas[aIdx].notebooks[nbIdx].notes[nIdx]
            mutate(&note)
            note.updatedAt = Date().timeIntervalSince1970
            store.doc.notes.areas[aIdx].notebooks[nbIdx].notes[nIdx] = note
            store.doc.updatedAt = note.updatedAt
            return
        }

        guard let nIdx = store.doc.notes.areas[aIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
        var note = store.doc.notes.areas[aIdx].notes[nIdx]
        mutate(&note)
        note.updatedAt = Date().timeIntervalSince1970
        store.doc.notes.areas[aIdx].notes[nIdx] = note
        store.doc.updatedAt = note.updatedAt
    }

    // ---- creation ----

    private func addArea() {
        store.addArea(title: "New Area")
    }

    private func addNotebook() {
        guard let areaID = store.doc.notes.selection.areaID else {
            addArea(); return
        }
        store.addNotebook(areaID: areaID, stackID: store.doc.notes.selection.stackID, title: "New Notebook")
    }

    private func addSection() {
        guard let areaID = store.doc.notes.selection.areaID,
              let notebookID = store.doc.notes.selection.notebookID else {
            addNotebook(); return
        }
        store.addSection(areaID: areaID, stackID: store.doc.notes.selection.stackID, notebookID: notebookID, title: "New Section")
    }

    private func addNote() {
        guard let areaID = store.doc.notes.selection.areaID else {
            addArea(); return
        }
        store.addNote(
            areaID: areaID,
            stackID: store.doc.notes.selection.stackID,
            notebookID: store.doc.notes.selection.notebookID,
            sectionID: store.doc.notes.selection.sectionID,
            title: ""
        )
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
                    .background(
                        RightClickCaptureView { screenPoint in
                            guard !store.isDraggingOverlay else { return }
                            store.notePointerLocation(screenPoint)

                            // Only show the tool palette on empty-board secondary click, while in Select tool.
                            guard store.currentTool == .select else { return }
                            guard store.topEntryAtScreenPoint(screenPoint) == nil else { return }

                            store.selection.removeAll()
                            activeTextEdit = nil

                            withAnimation(.easeOut(duration: 0.12)) {
                                store.showToolMenu(at: screenPoint)
                            }
                        }
                        .allowsHitTesting(false)
                    )

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
                    let isCirclePreview = store.currentTool == .circle || (store.currentTool == .rect && store.pendingShapeKind == .circle)
                    if isCirclePreview {
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
            .onChange(of: store.editingEntryID) { id in
                guard let id else {
                    activeTextEdit = nil
                    return
                }
                if store.doc.entries[id]?.type == .text {
                    activeTextEdit = id
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
        
        // Image actions
        if entry.type == .image {
            Button("Copy Image") { store.copyImageToPasteboard(id: entry.id) }
            Button("Save Image…") { store.saveImageEntryToDisk(id: entry.id) }
            Divider()
            if store.doc.ui.activeImageCropID == entry.id {
                Button("Done Cropping") { store.endImageCrop() }
            } else {
                Button("Crop…") { store.beginImageCrop(entry.id) }
            }
            if entry.imageCrop != nil {
                Button("Reset Crop") { store.resetImageCrop(entry.id) }
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
                    if let active = store.doc.ui.activeImageCropID, active != hit {
                        store.endImageCrop()
                    }
                } else {
                    // Left click empty board should NOT open the palette anymore.
                    store.selection.removeAll()
                    activeTextEdit = nil
                    if store.isToolMenuVisible {
                        withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu(suppressNextShow: false) }
                    }
                    store.endImageCrop()
                }

            case .text:
                withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                placeText(at: worldPoint(from: screenPoint))

            case .image:
                withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                promptImage(at: worldPoint(from: screenPoint))

            case .rect:
                withAnimation(.easeOut(duration: 0.12)) { store.hideToolMenu() }
                placeShape(kind: store.pendingShapeKind, at: worldPoint(from: screenPoint))

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
                        placeShape(kind: store.pendingShapeKind, at: worldPoint(from: screenPoint))

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
                let isCircleMarquee = store.currentTool == .circle || (store.currentTool == .rect && store.pendingShapeKind == .circle)

                let marqueeRect = isCircleMarquee
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
                    let baseRect = CGRect(origin: start, size: .zero).union(CGRect(origin: end, size: .zero))

                    let kind = store.pendingShapeKind
                    let frame = (kind == .circle) ? squareRect(from: start, to: end) : baseRect

                    let id = store.createEntry(type: .shape, frame: frame, data: .shape(kind))
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

        // Put it straight into "waiting for text" mode
        store.beginEditing(id)
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

        case .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
            rect = CGRect(x: point.x - 120, y: point.y - 80, width: 240, height: 160)
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

struct RightClickCaptureView: NSViewRepresentable {
    var onSecondaryClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onSecondaryClick = onSecondaryClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.onSecondaryClick = onSecondaryClick
    }

    private final class CaptureView: NSView {
        var onSecondaryClick: ((CGPoint) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let monitor { NSEvent.removeMonitor(monitor) }
            guard let window else { monitor = nil; return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let win = self.window, event.window === win else { return event }

                // Treat right-click OR control-click as "secondary click"
                let isSecondary =
                    event.type == .rightMouseDown ||
                    (event.type == .leftMouseDown && event.modifierFlags.contains(.control))

                guard isSecondary else { return event }

                guard let contentView = win.contentView else { return event }

                let p = event.locationInWindow
                let location = CGPoint(x: p.x, y: contentView.bounds.height - p.y) // flip Y into SwiftUI space
                self.onSecondaryClick?(location)

                // Don't consume — allow entry context menus to work normally.
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

struct NotesSidebarTree: View {
    @EnvironmentObject var store: BoardStore

    @Binding var sidebarCollapsed: Bool

    @State private var expandedAreas: Set<UUID> = []
    @State private var expandedStacks: Set<UUID> = []
    @State private var expandedNotebooks: Set<UUID> = []
    @State private var expandedSections: Set<UUID> = []

    // Search UI state
    @State private var isShowingSearch: Bool = false
    @State private var searchQuery: String = ""
    @State private var searchResults: [NoteSearchResult] = []

    private let standardPageCharacterCount = 1600
    private let maxPageIcons = 4

    // Drag payload is a plain string so we can use UTType.plainText everywhere.
    // Note format: fromArea|fromStack(optional)|fromNotebook(optional)|fromSection(optional)|noteID
    // Area format: area|areaID
    // Stack format: stack|fromArea|stackID
    // Notebook format: notebook|fromArea|fromStack(optional)|notebookID
    // Section format: section|fromArea|fromStack(optional)|fromNotebook|sectionID
    private func makeDragString(areaID: UUID, stackID: UUID?, notebookID: UUID?, sectionID: UUID?, noteID: UUID) -> String {
        let stack = stackID?.uuidString ?? ""
        let nb = notebookID?.uuidString ?? ""
        let sec = sectionID?.uuidString ?? ""
        return "\(areaID.uuidString)|\(stack)|\(nb)|\(sec)|\(noteID.uuidString)"
    }

    private func makeAreaDragString(areaID: UUID) -> String {
        "area|\(areaID.uuidString)"
    }

    private func makeStackDragString(areaID: UUID, stackID: UUID) -> String {
        "stack|\(areaID.uuidString)|\(stackID.uuidString)"
    }

    private func makeNotebookDragString(areaID: UUID, stackID: UUID?, notebookID: UUID) -> String {
        let stack = stackID?.uuidString ?? ""
        return "notebook|\(areaID.uuidString)|\(stack)|\(notebookID.uuidString)"
    }

    private func makeSectionDragString(areaID: UUID, stackID: UUID?, notebookID: UUID, sectionID: UUID) -> String {
        let stack = stackID?.uuidString ?? ""
        return "section|\(areaID.uuidString)|\(stack)|\(notebookID.uuidString)|\(sectionID.uuidString)"
    }

    private enum DragPayload {
        case note(fromArea: UUID, fromStack: UUID?, fromNotebook: UUID?, fromSection: UUID?, noteID: UUID)
        case area(areaID: UUID)
        case stack(fromArea: UUID, stackID: UUID)
        case notebook(fromArea: UUID, fromStack: UUID?, notebookID: UUID)
        case section(fromArea: UUID, fromStack: UUID?, fromNotebook: UUID, sectionID: UUID)
    }

    private enum DropTarget {
        case area(UUID)
        case stack(areaID: UUID, stackID: UUID)
        case notebook(areaID: UUID, stackID: UUID?, notebookID: UUID)
        case section(areaID: UUID, stackID: UUID?, notebookID: UUID, sectionID: UUID)
        case note(areaID: UUID, stackID: UUID?, notebookID: UUID?, sectionID: UUID?, noteID: UUID)
    }

    private enum DropPurpose {
        case moveInto
        case reorder
    }

    private func parseDragString(_ s: String) -> DragPayload? {
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "area" {
            guard parts.count == 2 else { return nil }
            guard let areaID = UUID(uuidString: parts[1]) else { return nil }
            return .area(areaID: areaID)
        }

        if parts.first == "stack" {
            guard parts.count == 3 else { return nil }
            guard let fromArea = UUID(uuidString: parts[1]) else { return nil }
            guard let stackID = UUID(uuidString: parts[2]) else { return nil }
            return .stack(fromArea: fromArea, stackID: stackID)
        }

        if parts.first == "notebook" {
            guard parts.count == 4 else { return nil }
            guard let fromArea = UUID(uuidString: parts[1]) else { return nil }
            let fromStack = parts[2].isEmpty ? nil : UUID(uuidString: parts[2])
            guard let notebookID = UUID(uuidString: parts[3]) else { return nil }
            return .notebook(fromArea: fromArea, fromStack: fromStack, notebookID: notebookID)
        }

        if parts.first == "section" {
            guard parts.count == 5 else { return nil }
            guard let fromArea = UUID(uuidString: parts[1]) else { return nil }
            let fromStack = parts[2].isEmpty ? nil : UUID(uuidString: parts[2])
            guard let fromNotebook = UUID(uuidString: parts[3]) else { return nil }
            guard let sectionID = UUID(uuidString: parts[4]) else { return nil }
            return .section(fromArea: fromArea, fromStack: fromStack, fromNotebook: fromNotebook, sectionID: sectionID)
        }

        guard parts.count == 5 else { return nil }
        guard let fromArea = UUID(uuidString: parts[0]) else { return nil }
        let fromStack = parts[1].isEmpty ? nil : UUID(uuidString: parts[1])
        let fromNotebook = parts[2].isEmpty ? nil : UUID(uuidString: parts[2])
        let fromSection = parts[3].isEmpty ? nil : UUID(uuidString: parts[3])
        guard let noteID = UUID(uuidString: parts[4]) else { return nil }
        return .note(fromArea: fromArea, fromStack: fromStack, fromNotebook: fromNotebook, fromSection: fromSection, noteID: noteID)
    }

    private func areaIndex(_ areaID: UUID) -> Int? {
        store.doc.notes.areas.firstIndex(where: { $0.id == areaID })
    }

    private func stackIndex(areaID: UUID, stackID: UUID) -> Int? {
        guard let aIdx = areaIndex(areaID) else { return nil }
        return store.doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID })
    }

    private func notebookIndex(areaID: UUID, stackID: UUID?, notebookID: UUID) -> Int? {
        guard let aIdx = areaIndex(areaID) else { return nil }
        if let stackID {
            guard let sIdx = store.doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return nil }
            return store.doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID })
        }
        return store.doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID })
    }

    private func sectionIndex(areaID: UUID, stackID: UUID?, notebookID: UUID, sectionID: UUID) -> Int? {
        guard let aIdx = areaIndex(areaID) else { return nil }
        if let stackID {
            guard let sIdx = store.doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return nil }
            guard let nbIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
            return store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID })
        }
        guard let nbIdx = store.doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
        return store.doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID })
    }

    private func noteIndex(areaID: UUID, stackID: UUID?, notebookID: UUID?, sectionID: UUID?, noteID: UUID) -> Int? {
        guard let aIdx = areaIndex(areaID) else { return nil }
        if let stackID {
            guard let sIdx = store.doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return nil }
            if let notebookID, let sectionID {
                guard let nbIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
                guard let secIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return nil }
                return store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.firstIndex(where: { $0.id == noteID })
            }
            if let notebookID {
                guard let nbIdx = store.doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
                return store.doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes.firstIndex(where: { $0.id == noteID })
            }
            return store.doc.notes.areas[aIdx].stacks[sIdx].notes.firstIndex(where: { $0.id == noteID })
        }
        if let notebookID, let sectionID {
            guard let nbIdx = store.doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
            guard let secIdx = store.doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return nil }
            return store.doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes.firstIndex(where: { $0.id == noteID })
        }
        if let notebookID {
            guard let nbIdx = store.doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
            return store.doc.notes.areas[aIdx].notebooks[nbIdx].notes.firstIndex(where: { $0.id == noteID })
        }
        return store.doc.notes.areas[aIdx].notes.firstIndex(where: { $0.id == noteID })
    }

    private func handleDrop(
        _ providers: [NSItemProvider],
        to target: DropTarget,
        insertAfter: Bool? = nil,
        purpose: DropPurpose
    ) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }

        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let s = (object as? NSString) as String? else { return }
            guard let payload = parseDragString(s) else { return }

            DispatchQueue.main.async {
                switch (payload, target) {
                case let (.note(fromArea, fromStack, fromNotebook, fromSection, noteID), .area(areaID)):
                    guard purpose == .moveInto else { break }
                    store.moveNote(
                        fromAreaID: fromArea,
                        fromStackID: fromStack,
                        fromNotebookID: fromNotebook,
                        fromSectionID: fromSection,
                        noteID: noteID,
                        toAreaID: areaID,
                        toStackID: nil,
                        toNotebookID: nil,
                        toSectionID: nil
                    )
                    expandedAreas.insert(areaID)
                case let (.note(fromArea, fromStack, fromNotebook, fromSection, noteID), .stack(areaID, stackID)):
                    guard purpose == .moveInto else { break }
                    store.moveNote(
                        fromAreaID: fromArea,
                        fromStackID: fromStack,
                        fromNotebookID: fromNotebook,
                        fromSectionID: fromSection,
                        noteID: noteID,
                        toAreaID: areaID,
                        toStackID: stackID,
                        toNotebookID: nil,
                        toSectionID: nil
                    )
                    expandedAreas.insert(areaID)
                    expandedStacks.insert(stackID)
                case let (.note(fromArea, fromStack, fromNotebook, fromSection, noteID), .notebook(areaID, stackID, notebookID)):
                    guard purpose == .moveInto else { break }
                    store.moveNote(
                        fromAreaID: fromArea,
                        fromStackID: fromStack,
                        fromNotebookID: fromNotebook,
                        fromSectionID: fromSection,
                        noteID: noteID,
                        toAreaID: areaID,
                        toStackID: stackID,
                        toNotebookID: notebookID,
                        toSectionID: nil
                    )
                    expandedAreas.insert(areaID)
                    if let stackID { expandedStacks.insert(stackID) }
                    expandedNotebooks.insert(notebookID)
                case let (.note(fromArea, fromStack, fromNotebook, fromSection, noteID), .section(areaID, stackID, notebookID, sectionID)):
                    guard purpose == .moveInto else { break }
                    store.moveNote(
                        fromAreaID: fromArea,
                        fromStackID: fromStack,
                        fromNotebookID: fromNotebook,
                        fromSectionID: fromSection,
                        noteID: noteID,
                        toAreaID: areaID,
                        toStackID: stackID,
                        toNotebookID: notebookID,
                        toSectionID: sectionID
                    )
                    expandedAreas.insert(areaID)
                    if let stackID { expandedStacks.insert(stackID) }
                    expandedNotebooks.insert(notebookID)
                    expandedSections.insert(sectionID)
                case let (.note(fromArea, fromStack, fromNotebook, fromSection, noteID), .note(areaID, stackID, notebookID, sectionID, targetNoteID)):
                    guard purpose == .reorder else { break }
                    guard let toIndex = noteIndex(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: sectionID, noteID: targetNoteID) else { break }
                    let insertIndex = insertAfter == true ? toIndex + 1 : toIndex
                    store.moveNote(
                        fromAreaID: fromArea,
                        fromStackID: fromStack,
                        fromNotebookID: fromNotebook,
                        fromSectionID: fromSection,
                        noteID: noteID,
                        toAreaID: areaID,
                        toStackID: stackID,
                        toNotebookID: notebookID,
                        toSectionID: sectionID,
                        toIndex: insertIndex
                    )
                    expandedAreas.insert(areaID)
                    if let stackID { expandedStacks.insert(stackID) }
                    if let notebookID { expandedNotebooks.insert(notebookID) }
                    if let sectionID { expandedSections.insert(sectionID) }
                case let (.area(fromAreaID), .area(toAreaID)):
                    guard purpose == .reorder else { break }
                    guard let toIndex = areaIndex(toAreaID) else { break }
                    let insertIndex = insertAfter == true ? toIndex + 1 : toIndex
                    store.moveArea(areaID: fromAreaID, toIndex: insertIndex)
                    expandedAreas.insert(toAreaID)
                case let (.stack(fromArea, stackID), .area(areaID)):
                    guard purpose == .moveInto else { break }
                    store.moveStack(fromAreaID: fromArea, stackID: stackID, toAreaID: areaID)
                    expandedAreas.insert(areaID)
                    expandedStacks.insert(stackID)
                case let (.stack(fromArea, stackID), .stack(areaID, targetStackID)):
                    guard purpose == .reorder else { break }
                    guard let toIndex = stackIndex(areaID: areaID, stackID: targetStackID) else { break }
                    let insertIndex = insertAfter == true ? toIndex + 1 : toIndex
                    store.moveStack(fromAreaID: fromArea, stackID: stackID, toAreaID: areaID, toIndex: insertIndex)
                    expandedAreas.insert(areaID)
                    expandedStacks.insert(stackID)
                case let (.notebook(fromArea, fromStack, notebookID), .area(areaID)):
                    guard purpose == .moveInto else { break }
                    store.moveNotebook(fromAreaID: fromArea, fromStackID: fromStack, notebookID: notebookID, toAreaID: areaID, toStackID: nil)
                    expandedAreas.insert(areaID)
                    expandedNotebooks.insert(notebookID)
                case let (.notebook(fromArea, fromStack, notebookID), .stack(areaID, stackID)):
                    guard purpose == .moveInto else { break }
                    store.moveNotebook(fromAreaID: fromArea, fromStackID: fromStack, notebookID: notebookID, toAreaID: areaID, toStackID: stackID)
                    expandedAreas.insert(areaID)
                    expandedStacks.insert(stackID)
                    expandedNotebooks.insert(notebookID)
                case let (.notebook(fromArea, fromStack, notebookID), .notebook(areaID, stackID, targetNotebookID)):
                    guard purpose == .reorder else { break }
                    guard let toIndex = notebookIndex(areaID: areaID, stackID: stackID, notebookID: targetNotebookID) else { break }
                    let insertIndex = insertAfter == true ? toIndex + 1 : toIndex
                    store.moveNotebook(fromAreaID: fromArea, fromStackID: fromStack, notebookID: notebookID, toAreaID: areaID, toStackID: stackID, toIndex: insertIndex)
                    expandedAreas.insert(areaID)
                    if let stackID { expandedStacks.insert(stackID) }
                    expandedNotebooks.insert(notebookID)
                case let (.section(fromArea, fromStack, fromNotebook, sectionID), .section(areaID, stackID, notebookID, targetSectionID)):
                    guard purpose == .reorder else { break }
                    guard let toIndex = sectionIndex(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: targetSectionID) else { break }
                    let insertIndex = insertAfter == true ? toIndex + 1 : toIndex
                    store.moveSection(
                        fromAreaID: fromArea,
                        fromStackID: fromStack,
                        fromNotebookID: fromNotebook,
                        sectionID: sectionID,
                        toAreaID: areaID,
                        toStackID: stackID,
                        toNotebookID: notebookID,
                        toIndex: insertIndex
                    )
                    expandedAreas.insert(areaID)
                    if let stackID { expandedStacks.insert(stackID) }
                    expandedNotebooks.insert(notebookID)
                    expandedSections.insert(sectionID)
                case let (.section(fromArea, fromStack, fromNotebook, sectionID), .notebook(areaID, stackID, notebookID)):
                    guard purpose == .moveInto else { break }
                    store.moveSection(
                        fromAreaID: fromArea,
                        fromStackID: fromStack,
                        fromNotebookID: fromNotebook,
                        sectionID: sectionID,
                        toAreaID: areaID,
                        toStackID: stackID,
                        toNotebookID: notebookID
                    )
                    expandedAreas.insert(areaID)
                    if let stackID { expandedStacks.insert(stackID) }
                    expandedNotebooks.insert(notebookID)
                default:
                    break
                }
            }
        }

        return true
    }

    private func reorderDropZone(target: DropTarget, indent: Int, insertAfter: Bool) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .padding(.leading, CGFloat(indent) * 14)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                handleDrop(providers, to: target, insertAfter: insertAfter, purpose: .reorder)
            }
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
                    ForEach(store.doc.notes.areas) { area in
                        reorderDropZone(target: .area(area.id), indent: 0, insertAfter: false)
                        DisclosureGroup(
                            isExpanded: bindingExpanded($expandedAreas, area.id)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                // area-level notes
                                ForEach(area.notes) { note in
                                    reorderDropZone(target: .note(areaID: area.id, stackID: nil, notebookID: nil, sectionID: nil, noteID: note.id), indent: 1, insertAfter: false)
                                    noteRow(
                                        title: note.displayTitle,
                                        locked: note.isLocked,
                                        indent: 1,
                                        isSelected: isSelected(area: area.id, stack: nil, notebook: nil, section: nil, note: note.id),
                                        pageCount: notePageCount(note)
                                    )
                                    .onTapGesture {
                                        Task {
                                            guard await store.ensureUnlockedForViewing(noteID: note.id) else { return }
                                            selectAreaNote(areaID: area.id, noteID: note.id)
                                        }
                                    }
                                    .onDrag { NSItemProvider(object: makeDragString(areaID: area.id, stackID: nil, notebookID: nil, sectionID: nil, noteID: note.id) as NSString)}
                                    .contextMenu {
                                        if note.isLocked {
                                            Button("Unlock Note…") {
                                                Task { await store.unlockNoteWithAuth(noteID: note.id) }
                                            }
                                        } else {
                                            Button("Lock Note…") {
                                                Task { await store.lockNoteWithAuth(noteID: note.id) }
                                            }
                                        }

                                        Divider()
                                        
                                        Button("Delete Note", role: .destructive) {
                                            confirmDelete(kind: "Note", name: note.displayTitle) {
                                                store.deleteNote(areaID: area.id, stackID: nil, notebookID: nil, sectionID: nil, noteID: note.id)
                                            }
                                        }
                                    }
                                }
                                if let last = area.notes.last {
                                    reorderDropZone(target: .note(areaID: area.id, stackID: nil, notebookID: nil, sectionID: nil, noteID: last.id), indent: 1, insertAfter: true)
                                }
                                ForEach(area.notebooks, id: \.id) { nb in
                                    reorderDropZone(target: .notebook(areaID: area.id, stackID: nil, notebookID: nb.id), indent: 1, insertAfter: false)
                                    DisclosureGroup(
                                        isExpanded: bindingExpanded($expandedNotebooks, nb.id)
                                    ) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            // notebook-level notes
                                            ForEach(nb.notes) { note in
                                                reorderDropZone(target: .note(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: nil, noteID: note.id), indent: 2, insertAfter: false)
                                                noteRow(
                                                    title: note.displayTitle,
                                                    locked: note.isLocked,
                                                    indent: 2,
                                                    isSelected: isSelected(area: area.id, stack: nil, notebook: nb.id, section: nil, note: note.id),
                                                    pageCount: notePageCount(note)
                                                )
                                                .onTapGesture {
                                                    Task {
                                                        guard await store.ensureUnlockedForViewing(noteID: note.id) else { return }
                                                        selectNote(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: nil, noteID: note.id)
                                                    }
                                                }
                                                .onDrag { NSItemProvider(object: makeDragString(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: nil, noteID: note.id) as NSString) }
                                                .contextMenu {
                                                    if note.isLocked {
                                                        Button("Unlock Note…") {
                                                            Task { await store.unlockNoteWithAuth(noteID: note.id) }
                                                        }
                                                    } else {
                                                        Button("Lock Note…") {
                                                            Task { await store.lockNoteWithAuth(noteID: note.id) }
                                                        }
                                                    }

                                                    Divider()
                                                    Button("Delete Note", role: .destructive) {
                                                        confirmDelete(kind: "Note", name: note.displayTitle) {
                                                            store.deleteNote(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: nil, noteID: note.id)
                                                        }
                                                    }
                                                }
                                            }
                                            if let last = nb.notes.last {
                                                reorderDropZone(target: .note(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: nil, noteID: last.id), indent: 2, insertAfter: true)
                                            }

                                            // sections
                                            ForEach(nb.sections) { section in
                                                reorderDropZone(target: .section(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id), indent: 2, insertAfter: false)
                                                DisclosureGroup(
                                                    isExpanded: bindingExpanded($expandedSections, section.id)
                                                ) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        ForEach(section.notes) { note in
                                                            reorderDropZone(target: .note(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id, noteID: note.id), indent: 3, insertAfter: false)
                                                            noteRow(
                                                                title: note.displayTitle,
                                                                locked: note.isLocked,
                                                                indent: 3,
                                                                isSelected: isSelected(area: area.id, stack: nil, notebook: nb.id, section: section.id, note: note.id),
                                                                pageCount: notePageCount(note)
                                                            )
                                                            .onTapGesture {
                                                                Task {
                                                                    guard await store.ensureUnlockedForViewing(noteID: note.id) else { return }
                                                                    selectNote(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id, noteID: note.id)
                                                                }
                                                            }
                                                            .onDrag { NSItemProvider(object: makeDragString(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id, noteID: note.id) as NSString)}
                                                            .contextMenu {
                                                                if note.isLocked {
                                                                    Button("Unlock Note…") {
                                                                        Task { await store.unlockNoteWithAuth(noteID: note.id) }
                                                                    }
                                                                } else {
                                                                    Button("Lock Note…") {
                                                                        Task { await store.lockNoteWithAuth(noteID: note.id) }
                                                                    }
                                                                }

                                                                Divider()
                                                                
                                                                Button("Delete Note", role: .destructive) {
                                                                    confirmDelete(kind: "Note", name: note.displayTitle) {
                                                                        store.deleteNote(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id, noteID: note.id)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        if let last = section.notes.last {
                                                            reorderDropZone(target: .note(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id, noteID: last.id), indent: 3, insertAfter: true)
                                                        }
                                                    }
                                                } label: {
                                                    folderRow(
                                                        title: section.title,
                                                        indent: 2,
                                            systemImage: isSelected(area: area.id, stack: nil, notebook: nb.id, section: section.id, note: nil)
                                                            ? "bookmark.fill"
                                                            : "bookmark",
                                                        count: section.notes.count,
                                                        isSelected: isSelected(area: area.id, stack: nil, notebook: nb.id, section: section.id, note: nil)
                                        )
                                        .onTapGesture {
                                            toggleExpanded(&expandedSections, section.id)
                                        }
                                                    .onDrag { NSItemProvider(object: makeSectionDragString(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id) as NSString) }
                                                    .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                                        handleDrop(providers, to: .section(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id), purpose: .moveInto)
                                                    }
                                                    .contextMenu {
                                                        Button("New Note") { store.addNote(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id) }

                                                        Divider()

                                                        Button("Rename Section") {
                                                            promptRename(kind: "Section", current: section.title) { newTitle in
                                                                store.renameSection(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id, title: newTitle)
                                                            }
                                                        }

                                                        Button("Delete Section", role: .destructive) {
                                                            confirmDelete(kind: "Section", name: section.title) {
                                                                expandedSections.remove(section.id)
                                                                store.deleteSection(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: section.id)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            if let last = nb.sections.last {
                                                reorderDropZone(target: .section(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: last.id), indent: 2, insertAfter: true)
                                            }
                                        }
                                        .padding(.leading, 14)
                                    } label: {
                                        folderRow(
                                            title: nb.title,
                                            indent: 1,
                                            systemImage: isSelected(area: area.id, stack: nil, notebook: nb.id, section: nil, note: nil)
                                                ? "book.closed.fill"
                                                : "book.closed",
                                            count: notebookNoteCount(nb),
                                            isSelected: isSelected(area: area.id, stack: nil, notebook: nb.id, section: nil, note: nil)
                                        )
                                        .onTapGesture {
                                            toggleExpanded(&expandedNotebooks, nb.id)
                                        }
                                        .onDrag { NSItemProvider(object: makeNotebookDragString(areaID: area.id, stackID: nil, notebookID: nb.id) as NSString) }
                                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                            handleDrop(providers, to: .notebook(areaID: area.id, stackID: nil, notebookID: nb.id), purpose: .moveInto)
                                        }
                                        .contextMenu {
                                            Button("New Section") { store.addSection(areaID: area.id, stackID: nil, notebookID: nb.id) }
                                            Button("New Note") { store.addNote(areaID: area.id, stackID: nil, notebookID: nb.id, sectionID: nil) }

                                            Divider()

                                            Button("Rename Notebook") {
                                                promptRename(kind: "Notebook", current: nb.title) { newTitle in
                                                    store.renameNotebook(areaID: area.id, stackID: nil, notebookID: nb.id, title: newTitle)
                                                }
                                            }

                                            Button("Delete Notebook", role: .destructive) {
                                                confirmDelete(kind: "Notebook", name: nb.title) {
                                                    expandedNotebooks.remove(nb.id)
                                                    for sec in nb.sections { expandedSections.remove(sec.id) }
                                                    store.deleteNotebook(areaID: area.id, stackID: nil, notebookID: nb.id)
                                                }
                                            }
                                        }
                                    }
                                }
                                if let last = area.notebooks.last {
                                    reorderDropZone(target: .notebook(areaID: area.id, stackID: nil, notebookID: last.id), indent: 1, insertAfter: true)
                                }

                                ForEach(area.stacks) { stack in
                                    reorderDropZone(target: .stack(areaID: area.id, stackID: stack.id), indent: 1, insertAfter: false)
                                    DisclosureGroup(
                                        isExpanded: bindingExpanded($expandedStacks, stack.id)
                                    ) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            // stack-level notes
                                            ForEach(stack.notes) { note in
                                                reorderDropZone(target: .note(areaID: area.id, stackID: stack.id, notebookID: nil, sectionID: nil, noteID: note.id), indent: 2, insertAfter: false)
                                                noteRow(
                                                    title: note.displayTitle,
                                                    locked: note.isLocked,
                                                    indent: 2,
                                                    isSelected: isSelected(area: area.id, stack: stack.id, notebook: nil, section: nil, note: note.id),
                                                    pageCount: notePageCount(note)
                                                )
                                                .onTapGesture {
                                                    Task {
                                                        guard await store.ensureUnlockedForViewing(noteID: note.id) else { return }
                                                        selectStackNote(areaID: area.id, stackID: stack.id, noteID: note.id)
                                                    }
                                                }
                                                .onDrag { NSItemProvider(object: makeDragString(areaID: area.id, stackID: stack.id, notebookID: nil, sectionID: nil, noteID: note.id) as NSString)}
                                                .contextMenu {
                                                    if note.isLocked {
                                                        Button("Unlock Note…") {
                                                            Task { await store.unlockNoteWithAuth(noteID: note.id) }
                                                        }
                                                    } else {
                                                        Button("Lock Note…") {
                                                            Task { await store.lockNoteWithAuth(noteID: note.id) }
                                                        }
                                                    }

                                                    Divider()

                                                    Button("Delete Note", role: .destructive) {
                                                        confirmDelete(kind: "Note", name: note.displayTitle) {
                                                            store.deleteNote(areaID: area.id, stackID: stack.id, notebookID: nil, sectionID: nil, noteID: note.id)
                                                        }
                                                    }
                                                }
                                            }
                                            if let last = stack.notes.last {
                                                reorderDropZone(target: .note(areaID: area.id, stackID: stack.id, notebookID: nil, sectionID: nil, noteID: last.id), indent: 2, insertAfter: true)
                                            }

                                            ForEach(stack.notebooks, id: \.id) { nb in
                                                reorderDropZone(target: .notebook(areaID: area.id, stackID: stack.id, notebookID: nb.id), indent: 2, insertAfter: false)
                                                DisclosureGroup(
                                                    isExpanded: bindingExpanded($expandedNotebooks, nb.id)
                                                ) {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        // notebook-level notes
                                                        ForEach(nb.notes) { note in
                                                            reorderDropZone(target: .note(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: note.id), indent: 3, insertAfter: false)
                                                            noteRow(
                                                                title: note.displayTitle,
                                                                locked: note.isLocked,
                                                                indent: 3,
                                                                isSelected: isSelected(area: area.id, stack: stack.id, notebook: nb.id, section: nil, note: note.id),
                                                                pageCount: notePageCount(note)
                                                            )
                                                            .onTapGesture {
                                                                Task {
                                                                    guard await store.ensureUnlockedForViewing(noteID: note.id) else { return }
                                                                    selectNote(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: note.id)
                                                                }
                                                            }
                                                            .onDrag { NSItemProvider(object: makeDragString(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: note.id) as NSString) }
                                                            .contextMenu {
                                                                if note.isLocked {
                                                                    Button("Unlock Note…") {
                                                                        Task { await store.unlockNoteWithAuth(noteID: note.id) }
                                                                    }
                                                                } else {
                                                                    Button("Lock Note…") {
                                                                        Task { await store.lockNoteWithAuth(noteID: note.id) }
                                                                    }
                                                                }

                                                                Divider()
                                                                Button("Delete Note", role: .destructive) {
                                                                    confirmDelete(kind: "Note", name: note.displayTitle) {
                                                                        store.deleteNote(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: note.id)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        if let last = nb.notes.last {
                                                            reorderDropZone(target: .note(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: nil, noteID: last.id), indent: 3, insertAfter: true)
                                                        }

                                                        // sections
                                                        ForEach(nb.sections) { section in
                                                            reorderDropZone(target: .section(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id), indent: 3, insertAfter: false)
                                                            DisclosureGroup(
                                                                isExpanded: bindingExpanded($expandedSections, section.id)
                                                            ) {
                                                                VStack(alignment: .leading, spacing: 2) {
                                                                    ForEach(section.notes) { note in
                                                                        reorderDropZone(target: .note(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: note.id), indent: 4, insertAfter: false)
                                                                        noteRow(
                                                                            title: note.displayTitle,
                                                                            locked: note.isLocked,
                                                                            indent: 4,
                                                                            isSelected: isSelected(area: area.id, stack: stack.id, notebook: nb.id, section: section.id, note: note.id),
                                                                            pageCount: notePageCount(note)
                                                                        )
                                                                        .onTapGesture {
                                                                            Task {
                                                                                guard await store.ensureUnlockedForViewing(noteID: note.id) else { return }
                                                                                selectNote(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: note.id)
                                                                            }
                                                                        }
                                                                        .onDrag { NSItemProvider(object: makeDragString(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: note.id) as NSString)}
                                                                        .contextMenu {
                                                                            if note.isLocked {
                                                                                Button("Unlock Note…") {
                                                                                    Task { await store.unlockNoteWithAuth(noteID: note.id) }
                                                                                }
                                                                            } else {
                                                                                Button("Lock Note…") {
                                                                                    Task { await store.lockNoteWithAuth(noteID: note.id) }
                                                                                }
                                                                            }

                                                                            Divider()
                                                                            
                                                                            Button("Delete Note", role: .destructive) {
                                                                                confirmDelete(kind: "Note", name: note.displayTitle) {
                                                                                    store.deleteNote(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: note.id)
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                    if let last = section.notes.last {
                                                                        reorderDropZone(target: .note(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id, noteID: last.id), indent: 4, insertAfter: true)
                                                                    }
                                                                }
                                                            } label: {
                                                                folderRow(
                                                                    title: section.title,
                                                                    indent: 3,
                                                                    systemImage: isSelected(area: area.id, stack: stack.id, notebook: nb.id, section: section.id, note: nil)
                                                                        ? "bookmark.fill"
                                                                        : "bookmark",
                                                                    count: section.notes.count,
                                                                    isSelected: isSelected(area: area.id, stack: stack.id, notebook: nb.id, section: section.id, note: nil)
                                                                )
                                                                .onTapGesture {
                                                                    toggleExpanded(&expandedSections, section.id)
                                                                }
                                                                .onDrag { NSItemProvider(object: makeSectionDragString(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id) as NSString) }
                                                                .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                                                    handleDrop(providers, to: .section(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id), purpose: .moveInto)
                                                                }
                                                                .contextMenu {
                                                                    Button("New Note") { store.addNote(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id) }

                                                                    Divider()

                                                                    Button("Rename Section") {
                                                                        promptRename(kind: "Section", current: section.title) { newTitle in
                                                                            store.renameSection(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id, title: newTitle)
                                                                        }
                                                                    }

                                                                    Button("Delete Section", role: .destructive) {
                                                                        confirmDelete(kind: "Section", name: section.title) {
                                                                            expandedSections.remove(section.id)
                                                                            store.deleteSection(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: section.id)
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        if let last = nb.sections.last {
                                                            reorderDropZone(target: .section(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: last.id), indent: 3, insertAfter: true)
                                                        }
                                                    }
                                                    .padding(.leading, 14)
                                                } label: {
                                                    folderRow(
                                                        title: nb.title,
                                                        indent: 2,
                                                        systemImage: isSelected(area: area.id, stack: stack.id, notebook: nb.id, section: nil, note: nil)
                                                            ? "book.closed.fill"
                                                            : "book.closed",
                                                        count: notebookNoteCount(nb),
                                                        isSelected: isSelected(area: area.id, stack: stack.id, notebook: nb.id, section: nil, note: nil)
                                                    )
                                                    .onTapGesture {
                                                        toggleExpanded(&expandedNotebooks, nb.id)
                                                    }
                                                    .onDrag { NSItemProvider(object: makeNotebookDragString(areaID: area.id, stackID: stack.id, notebookID: nb.id) as NSString) }
                                                    .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                                        handleDrop(providers, to: .notebook(areaID: area.id, stackID: stack.id, notebookID: nb.id), purpose: .moveInto)
                                                    }
                                                    .contextMenu {
                                                        Button("New Section") { store.addSection(areaID: area.id, stackID: stack.id, notebookID: nb.id) }
                                                        Button("New Note") { store.addNote(areaID: area.id, stackID: stack.id, notebookID: nb.id, sectionID: nil) }

                                                        Divider()

                                                        Button("Rename Notebook") {
                                                            promptRename(kind: "Notebook", current: nb.title) { newTitle in
                                                                store.renameNotebook(areaID: area.id, stackID: stack.id, notebookID: nb.id, title: newTitle)
                                                            }
                                                        }

                                                        Button("Delete Notebook", role: .destructive) {
                                                            confirmDelete(kind: "Notebook", name: nb.title) {
                                                                expandedNotebooks.remove(nb.id)
                                                                for sec in nb.sections { expandedSections.remove(sec.id) }
                                                                store.deleteNotebook(areaID: area.id, stackID: stack.id, notebookID: nb.id)
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
                                            indent: 1,
                                            systemImage: isSelected(area: area.id, stack: stack.id, notebook: nil, section: nil, note: nil)
                                                ? "square.stack.3d.up.fill"
                                                : "square.stack.3d.up",
                                            count: stackNoteCount(stack),
                                            isSelected: isSelected(area: area.id, stack: stack.id, notebook: nil, section: nil, note: nil)
                                        )
                                        .onTapGesture {
                                            toggleExpanded(&expandedStacks, stack.id)
                                        }
                                        .onDrag { NSItemProvider(object: makeStackDragString(areaID: area.id, stackID: stack.id) as NSString) }
                                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                            handleDrop(providers, to: .stack(areaID: area.id, stackID: stack.id), purpose: .moveInto)
                                        }
                                        .contextMenu {
                                            Button("New Note") { store.addNote(areaID: area.id, stackID: stack.id, notebookID: nil, sectionID: nil) }
                                            Button("New Notebook") { store.addNotebook(areaID: area.id, stackID: stack.id) }

                                            Divider()

                                            Button("Rename Stack") {
                                                promptRename(kind: "Stack", current: stack.title) { newTitle in
                                                    store.renameStack(areaID: area.id, stackID: stack.id, title: newTitle)
                                                }
                                            }

                                            Button("Delete Stack", role: .destructive) {
                                                confirmDelete(kind: "Stack", name: stack.title) {
                                                    expandedStacks.remove(stack.id)
                                                    for nb in stack.notebooks {
                                                        expandedNotebooks.remove(nb.id)
                                                        for sec in nb.sections { expandedSections.remove(sec.id) }
                                                    }
                                                    store.deleteStack(areaID: area.id, stackID: stack.id)
                                                }
                                            }
                                        }
                                    }
                                }
                                if let last = area.stacks.last {
                                    reorderDropZone(target: .stack(areaID: area.id, stackID: last.id), indent: 1, insertAfter: true)
                                }
                            }
                            .padding(.leading, 14)
                        } label: {
                            folderRow(
                                title: area.title,
                                indent: 0,
                                systemImage: "rectangle.3.group",
                                count: areaNoteCount(area),
                                isSelected: isSelected(area: area.id, stack: nil, notebook: nil, section: nil, note: nil)
                            )
                            .onTapGesture {
                                toggleExpanded(&expandedAreas, area.id)
                            }
                            .onDrag { NSItemProvider(object: makeAreaDragString(areaID: area.id) as NSString) }
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                handleDrop(providers, to: .area(area.id), purpose: .moveInto)
                            }
                            .contextMenu {
                                Button("New Note") { store.addNote(areaID: area.id, stackID: nil, notebookID: nil, sectionID: nil) }
                                Button("New Notebook") { store.addNotebook(areaID: area.id, stackID: nil) }
                                Button("New Stack") { store.addStack(areaID: area.id) }

                                if area.id != store.doc.notes.quickNotesAreaID {
                                    Divider()

                                    Button("Rename Area") {
                                        promptRename(kind: "Area", current: area.title) { newTitle in
                                            store.renameArea(id: area.id, title: newTitle)
                                        }
                                    }

                                    Button("Delete Area", role: .destructive) {
                                        confirmDelete(kind: "Area", name: area.title) {
                                            expandedAreas.remove(area.id)
                                            for stack in area.stacks {
                                                expandedStacks.remove(stack.id)
                                                for nb in stack.notebooks {
                                                    expandedNotebooks.remove(nb.id)
                                                    for sec in nb.sections { expandedSections.remove(sec.id) }
                                                }
                                            }
                                            for nb in area.notebooks {
                                                expandedNotebooks.remove(nb.id)
                                                for sec in nb.sections { expandedSections.remove(sec.id) }
                                            }
                                            store.deleteArea(id: area.id)
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
            // Apple Notes vibe: areas shown, but not necessarily expanded.
            // If you want them expanded by default, uncomment:
            // expandedAreas = Set(store.doc.notes.areas.map(\.id))
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
                        Task {
                            guard await store.ensureUnlockedForViewing(noteID: result.noteID) else { return }
                            selectNoteByID(result.noteID)
                            isShowingSearch = false
                        }
                    }
                )
                .environmentObject(store)
            }

            Menu {
                Button("Add Area") { store.addArea() }
                Button("Quick Note") { store.addQuickNote() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

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

    private func noteRow(title: String, locked: Bool, indent: Int, isSelected: Bool, pageCount: Int) -> some View {
        HStack(spacing: 8) {
            noteIcon(locked: locked, pageCount: pageCount)
                .frame(width: noteIconWidth(pageCount: pageCount), height: 16, alignment: .leading)

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

    private func noteIcon(locked: Bool, pageCount: Int) -> some View {
        let count = min(max(1, pageCount), maxPageIcons)
        return ZStack(alignment: .leading) {
            ForEach(0..<count, id: \.self) { index in
                let offsetIndex = count - 1 - index
                let isTop = index == 0
                Image(systemName: isTop ? (locked ? "lock.fill" : "text.page") : "text.page")
                    .foregroundStyle(isTop ? (locked ? .secondary : .primary) : .secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(NSColor.windowBackgroundColor))
                            .frame(width: 11, height: 14)
                    )
                    .offset(x: CGFloat(offsetIndex) * 2, y: CGFloat(offsetIndex) * -1)
                    .zIndex(Double(count - index))
            }
        }
    }

    private func noteIconWidth(pageCount: Int) -> CGFloat {
        let count = min(max(1, pageCount), maxPageIcons)
        return 16 + CGFloat(count - 1) * 2
    }

    private func notePageCount(_ note: NoteItem) -> Int {
        let content = (note.title + "\n" + note.bodyTextWithoutImages)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return 1 }
        let charCount = content.count
        return max(1, Int(ceil(Double(charCount) / Double(standardPageCharacterCount))))
    }

    // MARK: Selection helpers (adjust to match your NotesSelection)

    private func isSelected(area: UUID?, stack: UUID?, notebook: UUID?, section: UUID?, note: UUID?) -> Bool {
        let sel = store.doc.notes.selection
        return sel.areaID == area &&
            sel.stackID == stack &&
            sel.notebookID == notebook &&
            sel.sectionID == section &&
            sel.noteID == note
    }

    private func selectNote(areaID: UUID, stackID: UUID?, notebookID: UUID, sectionID: UUID?, noteID: UUID) {
        store.doc.notes.selection.areaID = areaID
        store.doc.notes.selection.stackID = stackID
        store.doc.notes.selection.notebookID = notebookID
        store.doc.notes.selection.sectionID = sectionID
        store.doc.notes.selection.noteID = noteID

        expandedAreas.insert(areaID)
        if let stackID { expandedStacks.insert(stackID) }
        expandedNotebooks.insert(notebookID)
        if let sectionID { expandedSections.insert(sectionID) }
    }

    private func selectAreaNote(areaID: UUID, noteID: UUID) {
        store.doc.notes.selection.areaID = areaID
        store.doc.notes.selection.stackID = nil
        store.doc.notes.selection.notebookID = nil
        store.doc.notes.selection.sectionID = nil
        store.doc.notes.selection.noteID = noteID
        expandedAreas.insert(areaID)
    }

    private func selectStackNote(areaID: UUID, stackID: UUID, noteID: UUID) {
        store.doc.notes.selection.areaID = areaID
        store.doc.notes.selection.stackID = stackID
        store.doc.notes.selection.notebookID = nil
        store.doc.notes.selection.sectionID = nil
        store.doc.notes.selection.noteID = noteID
        expandedAreas.insert(areaID)
        expandedStacks.insert(stackID)
    }

    /// Selects a note anywhere in the workspace and ensures its containers are expanded.
    private func selectNoteByID(_ noteID: UUID) {
        for area in store.doc.notes.areas {
            // Area-level note
            if area.notes.contains(where: { $0.id == noteID }) {
                selectAreaNote(areaID: area.id, noteID: noteID)
                return
            }

            // Area notebooks
            for notebook in area.notebooks {
                if notebook.notes.contains(where: { $0.id == noteID }) {
                    selectNote(areaID: area.id, stackID: nil, notebookID: notebook.id, sectionID: nil, noteID: noteID)
                    return
                }
                for section in notebook.sections {
                    if section.notes.contains(where: { $0.id == noteID }) {
                        selectNote(areaID: area.id, stackID: nil, notebookID: notebook.id, sectionID: section.id, noteID: noteID)
                        return
                    }
                }
            }

            for stack in area.stacks {
                // Stack-level note
                if stack.notes.contains(where: { $0.id == noteID }) {
                    selectStackNote(areaID: area.id, stackID: stack.id, noteID: noteID)
                    return
                }

                // Notebook + section notes
                for notebook in stack.notebooks {
                    if notebook.notes.contains(where: { $0.id == noteID }) {
                        selectNote(areaID: area.id, stackID: stack.id, notebookID: notebook.id, sectionID: nil, noteID: noteID)
                        return
                    }
                    for section in notebook.sections {
                        if section.notes.contains(where: { $0.id == noteID }) {
                            selectNote(areaID: area.id, stackID: stack.id, notebookID: notebook.id, sectionID: section.id, noteID: noteID)
                            return
                        }
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

    private func areaNoteCount(_ area: NoteArea) -> Int {
        area.notes.count
            + area.notebooks.reduce(0) { $0 + notebookNoteCount($1) }
            + area.stacks.reduce(0) { $0 + stackNoteCount($1) }
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

        for area in store.doc.notes.areas {
            let areaPath = "Area: \(area.title)"

            // Area-level notes
            for note in area.notes {
                if let hit = score(note: note, path: areaPath, queryLower: queryLower, queryOriginal: trimmed) {
                    results.append(hit)
                }
            }

            // Area notebooks
            for notebook in area.notebooks {
                let notebookPath = "\(areaPath) > Notebook: \(notebook.title)"

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

            for stack in area.stacks {
                let stackPath = "\(areaPath) > Stack: \(stack.title)"

                // Stack-level notes
                for note in stack.notes {
                    if let hit = score(note: note, path: stackPath, queryLower: queryLower, queryOriginal: trimmed) {
                        results.append(hit)
                    }
                }

                // Stack notebooks
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
        }

        results.sort { $0.score > $1.score }
        searchResults = Array(results.prefix(50))
    }

    private func score(note: NoteItem, path: String, queryLower: String, queryOriginal: String) -> NoteSearchResult? {
        let titleLower = note.displayTitle.lowercased()
        let bodyLower = note.bodyTextWithoutImages.lowercased()
        let pathLower = path.lowercased()

        var score = 0
        if titleLower.contains(queryLower) { score += 10 }
        if pathLower.contains(queryLower) { score += 3 }
        if bodyLower.contains(queryLower) { score += 1 }

        guard score > 0 else { return nil }

        let body = note.bodyTextWithoutImages
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

    private func createArea() {
        store.addArea(title: "New Area")
    }

    private func createStack(areaID: UUID) {
        store.addStack(areaID: areaID, title: "New Stack")
        expandedAreas.insert(areaID)
    }

    private func createNotebook(areaID: UUID, stackID: UUID?) {
        store.addNotebook(areaID: areaID, stackID: stackID, title: "New Notebook")
        expandedAreas.insert(areaID)
        if let stackID { expandedStacks.insert(stackID) }
    }

    private func createSection(areaID: UUID, stackID: UUID?, notebookID: UUID) {
        store.addSection(areaID: areaID, stackID: stackID, notebookID: notebookID, title: "New Section")
        expandedAreas.insert(areaID)
        if let stackID { expandedStacks.insert(stackID) }
        expandedNotebooks.insert(notebookID)
    }

    private func createNote(areaID: UUID, stackID: UUID?, notebookID: UUID?, sectionID: UUID?) {
        store.addNote(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: sectionID, title: "New Note")
        expandedAreas.insert(areaID)
        if let stackID { expandedStacks.insert(stackID) }
        if let notebookID { expandedNotebooks.insert(notebookID) }
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
                Text("Type to search across all areas, stacks, notebooks, sections, and notes.")
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
