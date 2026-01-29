import Foundation
import CoreGraphics

enum EntryType: String, Codable {
    case text, image, file, shape, line
}

enum Actor: String, Codable {
    case user, model
}

enum ShapeKind: String, Codable {
    case rect
    case circle
    case triangleUp
    case triangleDown
    case triangleLeft
    case triangleRight
}

struct ColorComponents: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
}

struct ShapeStyle: Codable, Hashable {
    var fillColor: ColorComponents
    var fillOpacity: Double
    var borderColor: ColorComponents
    var borderOpacity: Double
    var borderWidth: Double

    static func `default`(for kind: ShapeKind) -> ShapeStyle {
        switch kind {
        case .rect, .circle, .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
            return ShapeStyle(fillColor: ColorComponents(red: 0.6, green: 0.6, blue: 0.6),
                            fillOpacity: 1.0,
                            borderColor: ColorComponents(red: 0.6, green: 0.6, blue: 0.6),
                            borderOpacity: 0.0,
                            borderWidth: 0)
        }
    }
}

struct TextStyle: Codable, Hashable {
    static let systemFontName = "System"

    var fontName: String
    var fontSize: Double
    var textColor: ColorComponents
    var textOpacity: Double
    var outlineColor: ColorComponents
    var outlineWidth: Double

    static func `default`() -> TextStyle {
        TextStyle(fontName: systemFontName,
                  fontSize: 14,
                  textColor: ColorComponents(red: 0, green: 0, blue: 0),
                  textOpacity: 1,
                  outlineColor: ColorComponents(red: 0, green: 0, blue: 0),
                  outlineWidth: 0)
    }
}

struct Point: Codable, Hashable {
    var x: Double
    var y: Double
}

struct LineData: Codable {
    var points: [Point]
    var arrow: Bool
}

struct ImageRef: Codable, Hashable {
    var filename: String
}

struct FileRef: Codable, Hashable {
    var filename: String
    var originalName: String
}

extension FileRef {
    var displayName: String {
        let trimmed = originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? filename : trimmed
    }
}

enum EntryData: Codable {
    case text(String)
    case image(ImageRef)
    case file(FileRef)
    case shape(ShapeKind)
    case line(LineData)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image
        case file
        case shape
        case line
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let value = try container.decode(String.self, forKey: .text)
            self = .text(value)
        case "image":
            let value = try container.decode(ImageRef.self, forKey: .image)
            self = .image(value)
        case "file":
            let value = try container.decode(FileRef.self, forKey: .file)
            self = .file(value)
        case "shape":
            let value = try container.decode(ShapeKind.self, forKey: .shape)
            self = .shape(value)
        case "line":
            let value = try container.decode(LineData.self, forKey: .line)
            self = .line(value)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown EntryData type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let ref):
            try container.encode("image", forKey: .type)
            try container.encode(ref, forKey: .image)
        case .file(let ref):
            try container.encode("file", forKey: .type)
            try container.encode(ref, forKey: .file)
        case .shape(let kind):
            try container.encode("shape", forKey: .type)
            try container.encode(kind, forKey: .shape)
        case .line(let data):
            try container.encode("line", forKey: .type)
            try container.encode(data, forKey: .line)
        }
    }
}

struct Viewport: Codable {
    var offsetX: Double
    var offsetY: Double
    var zoom: Double
}

struct BoardEntry: Codable, Identifiable {
    var id: UUID
    var type: EntryType
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var locked: Bool
    var createdBy: Actor
    var createdAt: Double
    var updatedAt: Double
    var data: EntryData
    var shapeStyle: ShapeStyle?
    var textStyle: TextStyle?
}

struct WebSearchItem: Codable, Hashable {
    var title: String
    var url: String
    var snippet: String?
}

struct WebSearchPayload: Codable, Hashable {
    var query: String
    var items: [WebSearchItem]
}

struct ChatMsg: Codable, Identifiable {
    var id: UUID
    var role: Actor
    var text: String
    var images: [ImageRef]
    var files: [FileRef]
    var webSearch: WebSearchPayload?
    var ts: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case image
        case images
        case ts
        case files
        case webSearch
    }

    init(id: UUID, role: Actor, text: String, images: [ImageRef], files: [FileRef], ts: Double) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.files = files
        self.ts = ts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Actor.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        ts = try container.decode(Double.self, forKey: .ts)
        if let images = try container.decodeIfPresent([ImageRef].self, forKey: .images) {
            self.images = images
        } else if let image = try container.decodeIfPresent(ImageRef.self, forKey: .image) {
            self.images = [image]
        } else {
            self.images = []
        }
        files = try container.decodeIfPresent([FileRef].self, forKey: .files) ?? []
        webSearch = try container.decodeIfPresent(WebSearchPayload.self, forKey: .webSearch)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(ts, forKey: .ts)
        if !images.isEmpty {
            try container.encode(images, forKey: .images)
        }
        if !files.isEmpty {
            try container.encode(files, forKey: .files)
        }
        if let webSearch {
            try container.encode(webSearch, forKey: .webSearch)
        }
    }
}

struct ChatThread: Codable {
    var id: UUID
    var messages: [ChatMsg]
    var title: String?

    private enum CodingKeys: String, CodingKey {
        case id, messages, title
    }

    init(id: UUID, messages: [ChatMsg], title: String? = nil) {
        self.id = id
        self.messages = messages
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        messages = try container.decode([ChatMsg].self, forKey: .messages)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

struct ChatSettings: Codable {
    static let defaultModel = "gpt-5.2"
    static let defaultVoice = "nova"
    static let defaultAlwaysListening = false
    static let availableVoices = [
        "alloy",
        "ash",
        "coral",
        "echo",
        "fable",
        "nova",
        "onyx",
        "sage",
        "shimmer"
    ]
    static let defaultSettings = ChatSettings(model: defaultModel, apiKey: "", personality: "", userName: "")

    var model: String
    var apiKey: String
    var personality: String
    var userName: String
    var voice: String
    var alwaysListening: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case apiKey
        case personality
        case userName
        case voice
        case alwaysListening
    }

    init(model: String,
         apiKey: String,
         personality: String,
         userName: String,
         voice: String = ChatSettings.defaultVoice,
         alwaysListening: Bool = ChatSettings.defaultAlwaysListening) {
        self.model = model
        self.apiKey = apiKey
        self.personality = personality
        self.userName = userName
        self.voice = ChatSettings.availableVoices.contains(voice) ? voice : ChatSettings.defaultVoice
        self.alwaysListening = alwaysListening
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        personality = try container.decode(String.self, forKey: .personality)
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
        let rawVoice = try container.decodeIfPresent(String.self, forKey: .voice) ?? Self.defaultVoice
        voice = Self.availableVoices.contains(rawVoice) ? rawVoice : Self.defaultVoice
        alwaysListening = try container.decodeIfPresent(Bool.self, forKey: .alwaysListening) ?? Self.defaultAlwaysListening
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(personality, forKey: .personality)
        try container.encode(userName, forKey: .userName)
        try container.encode(voice, forKey: .voice)
        try container.encode(alwaysListening, forKey: .alwaysListening)
    }
}

// MARK: - Reminders

struct ReminderRecurrence: Codable {
    enum Frequency: String, Codable {
        case hourly
        case daily
        case weekly
        case monthly
        case yearly
    }

    var frequency: Frequency
    var interval: Int
    /// Calendar weekday integers (1=Sunday ... 7=Saturday). Only used for weekly.
    var weekdays: [Int]?

    init(frequency: Frequency, interval: Int = 1, weekdays: [Int]? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
    }
}

struct ReminderItem: Codable, Identifiable {
    enum Status: String, Codable {
        case scheduled
        case preparing
        case ready
        case fired
        case cancelled
    }

    var id: UUID
    var createdAt: Double
    var title: String
    /// What the user asked for. This is what the model "does" at reminder time.
    var work: String
    /// Next time this reminder should fire (unix seconds).
    var dueAt: Double
    var recurrence: ReminderRecurrence?

    /// Cached model output prepared during the next reminder check.
    var preparedMessage: String?
    var status: Status

    init(id: UUID = UUID(),
         createdAt: Double = Date().timeIntervalSince1970,
         title: String,
         work: String,
         dueAt: Double,
         recurrence: ReminderRecurrence? = nil,
         preparedMessage: String? = nil,
         status: Status = .scheduled) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.work = work
        self.dueAt = dueAt
        self.recurrence = recurrence
        self.preparedMessage = preparedMessage
        self.status = status
    }
}

enum MemoryCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case unchangeable = "unchangeable"
    case longTerm = "long_term"
    case shortTerm = "short_term"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unchangeable: return "Unchangeable"
        case .longTerm: return "Long Term"
        case .shortTerm: return "Short Term"
        }
    }

    static func fromString(_ raw: String) -> MemoryCategory? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "unchangeable", "unchangable", "immutable", "permanent", "facts", "fact":
            return .unchangeable
        case "long_term", "longterm", "long":
            return .longTerm
        case "short_term", "shortterm", "short":
            return .shortTerm
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = MemoryCategory.fromString(raw) ?? .longTerm
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct Memory: Codable, Identifiable, Hashable {
    var id: UUID
    var text: String
    var image: ImageRef? // nil for text-only memories
    var createdAt: Double
    var category: MemoryCategory

    init(id: UUID = UUID(),
         text: String,
         image: ImageRef? = nil,
         createdAt: Double = Date().timeIntervalSince1970,
         category: MemoryCategory = .longTerm) {
        self.id = id
        self.text = text
        self.image = image
        self.createdAt = createdAt
        self.category = category
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case image
        case createdAt
        case category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        image = try? container.decodeIfPresent(ImageRef.self, forKey: .image)
        createdAt = (try? container.decodeIfPresent(Double.self, forKey: .createdAt))
            ?? Date().timeIntervalSince1970
        category = (try? container.decodeIfPresent(MemoryCategory.self, forKey: .category))
            ?? .longTerm
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(category, forKey: .category)
    }
}

struct LogItem: Codable, Identifiable {
    var id: UUID
    var ts: Double
    var actor: Actor
    var summary: String
    var relatedEntryIds: [UUID]?
    var relatedChatId: UUID?
}

struct FloatingBox: Codable {
    var isVisible: Bool
    var x: Double
    var y: Double
}

struct PanelBox: Codable {
    var isOpen: Bool
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct PanelsState: Codable {
    var chat: PanelBox
    var chatArchive: PanelBox
    var log: PanelBox
    var memories: PanelBox
    var shapeStyle: PanelBox
    var settings: PanelBox
    var personality: PanelBox
    var reminder: PanelBox // New property

    private enum CodingKeys: String, CodingKey {
        case chat
        case chatArchive
        case log
        case memories
        case shapeStyle
        case settings
        case personality
        case reminder // New case
    }

    init(
        chat: PanelBox,
        chatArchive: PanelBox,
        log: PanelBox,
        memories: PanelBox,
        shapeStyle: PanelBox,
        settings: PanelBox,
        personality: PanelBox,
        reminder: PanelBox // New parameter
    ) {
        self.chat = chat
        self.chatArchive = chatArchive
        self.log = log
        self.memories = memories
        self.shapeStyle = shapeStyle
        self.settings = settings
        self.personality = personality
        self.reminder = reminder // Assign new property
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chat = try container.decode(PanelBox.self, forKey: .chat)
        chatArchive = try container.decodeIfPresent(PanelBox.self, forKey: .chatArchive)
            ?? PanelBox(isOpen: false, x: 320, y: 140, w: 420, h: 520)
        log = try container.decode(PanelBox.self, forKey: .log)

        memories = try container.decodeIfPresent(PanelBox.self, forKey: .memories)
            ?? PanelBox(isOpen: false, x: 300, y: 200, w: 420, h: 520)

        shapeStyle = try container.decodeIfPresent(PanelBox.self, forKey: .shapeStyle)
            ?? PanelBox(isOpen: false, x: 640, y: 140, w: 360, h: 320)
        settings = try container.decodeIfPresent(PanelBox.self, forKey: .settings)
            ?? PanelBox(isOpen: false, x: 600, y: 120, w: 460, h: 520)
        personality = try container.decodeIfPresent(PanelBox.self, forKey: .personality)
            ?? PanelBox(isOpen: false, x: 640, y: 360, w: 380, h: 320)
        reminder = try container.decodeIfPresent(PanelBox.self, forKey: .reminder) // Decode new property
            ?? PanelBox(isOpen: false, x: 420, y: 120, w: 360, h: 260) // Default value for reminder panel
    }
}

// MARK: - Workspace Mode

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case canvas
    case notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .canvas: return "Canvas"
        case .notes: return "Notes"
        }
    }
}

// MARK: - Notes Workspace

struct NotesSelection: Codable, Hashable {
    var stackID: UUID?
    var notebookID: UUID?
    var sectionID: UUID?
    var noteID: UUID?
}

struct NoteItem: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Double
    var updatedAt: Double
}

extension NoteItem {
    /// Sidebar/Lists title: prefers `title`, otherwise uses the first few words of `body`.
    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty { return "Untitled" }

        // Collapse whitespace/newlines, take first N words.
        let normalized = trimmedBody
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let words = normalized.split(whereSeparator: { $0.isWhitespace })
        let maxWords = 8

        if words.count <= maxWords {
            return words.map(String.init).joined(separator: " ")
        } else {
            return words.prefix(maxWords).map(String.init).joined(separator: " ") + "…"
        }
    }
}

struct NoteSection: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var notes: [NoteItem]
}

struct NoteNotebook: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var sections: [NoteSection]
    var notes: [NoteItem]

    init(id: UUID, title: String, sections: [NoteSection], notes: [NoteItem] = []) {
        self.id = id
        self.title = title
        self.sections = sections
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case id, title, sections, notes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        sections = try c.decodeIfPresent([NoteSection].self, forKey: .sections) ?? []
        notes = try c.decodeIfPresent([NoteItem].self, forKey: .notes) ?? []
    }
}

struct NoteStack: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var notebooks: [NoteNotebook]
    var notes: [NoteItem]

    init(id: UUID, title: String, notebooks: [NoteNotebook], notes: [NoteItem] = []) {
        self.id = id
        self.title = title
        self.notebooks = notebooks
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case id, title, notebooks, notes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notebooks = try c.decodeIfPresent([NoteNotebook].self, forKey: .notebooks) ?? []
        notes = try c.decodeIfPresent([NoteItem].self, forKey: .notes) ?? []
    }
}

struct NotesWorkspace: Codable {
    var stacks: [NoteStack]
    var selection: NotesSelection
    var sidebarCollapsed: Bool
    /// The dedicated stack that holds Quick Notes. This one cannot be renamed or deleted.
    var quickNotesStackID: UUID

    static func `default`(now: Double = Date().timeIntervalSince1970) -> NotesWorkspace {
        let quickStackID = UUID()
        let quickStack = NoteStack(
            id: quickStackID,
            title: "Quick Notes",
            notebooks: [],
            notes: []
        )

        return NotesWorkspace(
            stacks: [quickStack],
            selection: NotesSelection(stackID: quickStackID, notebookID: nil, sectionID: nil, noteID: nil),
            sidebarCollapsed: false,
            quickNotesStackID: quickStackID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case stacks, selection, sidebarCollapsed, quickNotesStackID
    }

    init(stacks: [NoteStack], selection: NotesSelection, sidebarCollapsed: Bool, quickNotesStackID: UUID) {
        self.stacks = stacks
        self.selection = selection
        self.sidebarCollapsed = sidebarCollapsed
        self.quickNotesStackID = quickNotesStackID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decodedStacks = try c.decodeIfPresent([NoteStack].self, forKey: .stacks) ?? []
        let decodedSelection = try c.decodeIfPresent(NotesSelection.self, forKey: .selection) ?? NotesSelection()
        let decodedCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false

        let qID = try c.decodeIfPresent(UUID.self, forKey: .quickNotesStackID)
        let quickID: UUID
        if let qID {
            quickID = qID
        } else if let existing = decodedStacks.first(where: { $0.title == "Quick Notes" }) {
            quickID = existing.id
        } else {
            let newID = UUID()
            decodedStacks.insert(NoteStack(id: newID, title: "Quick Notes", notebooks: [], notes: []), at: 0)
            quickID = newID
        }

        var fixedSelection = decodedSelection
        if fixedSelection.stackID == nil || !decodedStacks.contains(where: { $0.id == fixedSelection.stackID }) {
            fixedSelection.stackID = quickID
            fixedSelection.notebookID = nil
            fixedSelection.sectionID = nil
            fixedSelection.noteID = nil
        }

        self.stacks = decodedStacks
        self.selection = fixedSelection
        self.sidebarCollapsed = decodedCollapsed
        self.quickNotesStackID = quickID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stacks, forKey: .stacks)
        try c.encode(selection, forKey: .selection)
        try c.encode(sidebarCollapsed, forKey: .sidebarCollapsed)
        try c.encode(quickNotesStackID, forKey: .quickNotesStackID)
    }
}

struct UIState: Codable {
    static let defaultHUDBarColor = ColorComponents(red: 0.93, green: 0.9, blue: 0.98)

    var hud: FloatingBox
    var panels: PanelsState
    var hudBarColor: ColorComponents
    var hudBarOpacity: Double
    var workspaceMode: WorkspaceMode

    init(
        hud: FloatingBox,
        panels: PanelsState,
        workspaceMode: WorkspaceMode = .canvas,
        hudBarColor: ColorComponents = UIState.defaultHUDBarColor,
        hudBarOpacity: Double = 1.0
    ) {
        self.hud = hud
        self.panels = panels
        self.workspaceMode = workspaceMode
        self.hudBarColor = hudBarColor
        self.hudBarOpacity = hudBarOpacity
    }

    private enum CodingKeys: String, CodingKey {
        case hud
        case panels
        case workspaceMode
        case hudBarColor
        case hudBarOpacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hud = try container.decode(FloatingBox.self, forKey: .hud)
        panels = try container.decode(PanelsState.self, forKey: .panels)
        workspaceMode = try container.decodeIfPresent(WorkspaceMode.self, forKey: .workspaceMode) ?? .canvas
        hudBarColor = try container.decodeIfPresent(ColorComponents.self, forKey: .hudBarColor)
            ?? UIState.defaultHUDBarColor
        hudBarOpacity = try container.decodeIfPresent(Double.self, forKey: .hudBarOpacity) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hud, forKey: .hud)
        try container.encode(panels, forKey: .panels)
        try container.encode(workspaceMode, forKey: .workspaceMode) // ✅ add
        try container.encode(hudBarColor, forKey: .hudBarColor)
        try container.encode(hudBarOpacity, forKey: .hudBarOpacity)
    }
}

struct BoardDoc: Codable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var viewport: Viewport
    var entries: [UUID: BoardEntry]
    var zOrder: [UUID]
    var chat: ChatThread
    var chatSettings: ChatSettings = ChatSettings.defaultSettings
    var chatHistory: [ChatThread]
    var pendingClarification: PendingClarification?
    var memories: [Memory]
    var log: [LogItem]
    var ui: UIState
    var reminders: [ReminderItem]
    var notes: NotesWorkspace

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case viewport
        case entries
        case zOrder
        case chat
        case chatSettings
        case chatHistory
        case pendingClarification
        case memories
        case log
        case ui
        case reminders
        case notes
    }

    init(
        id: UUID,
        title: String,
        createdAt: Double,
        updatedAt: Double,
        viewport: Viewport,
        entries: [UUID: BoardEntry],
        zOrder: [UUID],
        chat: ChatThread,
        chatSettings: ChatSettings,
        chatHistory: [ChatThread],
        pendingClarification: PendingClarification?,
        memories: [Memory],
        log: [LogItem],
        ui: UIState
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.viewport = viewport
        self.entries = entries
        self.zOrder = zOrder
        self.chat = chat
        self.chatSettings = chatSettings
        self.chatHistory = chatHistory
        self.pendingClarification = pendingClarification
        self.memories = memories
        self.log = log
        self.ui = ui
        self.reminders = []
        self.notes = NotesWorkspace.default(now: createdAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Double.self, forKey: .createdAt)
        updatedAt = try container.decode(Double.self, forKey: .updatedAt)
        viewport = try container.decode(Viewport.self, forKey: .viewport)
        entries = try container.decode([UUID: BoardEntry].self, forKey: .entries)
        zOrder = try container.decode([UUID].self, forKey: .zOrder)
        chat = try container.decode(ChatThread.self, forKey: .chat)
        chatSettings = try container.decodeIfPresent(ChatSettings.self, forKey: .chatSettings)
            ?? ChatSettings.defaultSettings
        chatHistory = try container.decodeIfPresent([ChatThread].self, forKey: .chatHistory) ?? []
        pendingClarification = try container.decodeIfPresent(PendingClarification.self, forKey: .pendingClarification)
        reminders = try container.decodeIfPresent([ReminderItem].self, forKey: .reminders) ?? []

        notes = try container.decodeIfPresent(NotesWorkspace.self, forKey: .notes)
        ?? NotesWorkspace.default(now: Date().timeIntervalSince1970)

        // ✅ back-compat: older docs may not have this key
        if let memories = try? container.decodeIfPresent([Memory].self, forKey: .memories) {
            self.memories = memories ?? []
        } else if let oldMemories = try? container.decodeIfPresent([String].self, forKey: .memories) {
            self.memories = (oldMemories ?? []).map { Memory(text: $0) }
        } else {
            self.memories = []
        }

        log = try container.decode([LogItem].self, forKey: .log)
        ui = try container.decode(UIState.self, forKey: .ui)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(entries, forKey: .entries)
        try container.encode(zOrder, forKey: .zOrder)
        try container.encode(chat, forKey: .chat)
        try container.encode(chatSettings, forKey: .chatSettings)
        try container.encode(chatHistory, forKey: .chatHistory)
        try container.encode(pendingClarification, forKey: .pendingClarification)
        try container.encode(memories, forKey: .memories)
        try container.encode(log, forKey: .log)
        try container.encode(ui, forKey: .ui)
        try container.encode(reminders, forKey: .reminders)
        try container.encode(notes, forKey: .notes)
    }
}

enum BoardTool: String, CaseIterable, Identifiable {
    case select
    case text
    case image
    case rect
    case circle
    case line

    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: return "Select"
        case .text: return "Text"
        case .image: return "Image"
        case .rect: return "Rect"
        case .circle: return "Circle"
        case .line: return "Line"
        }
    }
}

extension BoardTool {
    var allowsPanGesture: Bool {
        switch self {
        case .rect, .circle, .line:
            return false
        default:
            return true
        }
    }
}

extension BoardDoc {
    static func defaultDoc() -> BoardDoc {
        let now = Date().timeIntervalSince1970
        let hud = FloatingBox(isVisible: true, x: 40, y: 40)
        let panels = PanelsState(
            chat: PanelBox(isOpen: false, x: 240, y: 120, w: 420, h: 520),
            chatArchive: PanelBox(isOpen: false, x: 320, y: 140, w: 420, h: 520),
            log: PanelBox(isOpen: false, x: 280, y: 180, w: 420, h: 520),
            memories: PanelBox(isOpen: false, x: 300, y: 200, w: 420, h: 520),
            shapeStyle: PanelBox(isOpen: false, x: 640, y: 140, w: 360, h: 320),
            settings: PanelBox(isOpen: false, x: 600, y: 120, w: 460, h: 520),
            personality: PanelBox(isOpen: false, x: 640, y: 360, w: 380, h: 320),
            reminder: PanelBox(isOpen: false, x: 420, y: 120, w: 360, h: 260) // Initialize new reminder panel
        )
        return BoardDoc(
            id: UUID(),
            title: "Untitled Board",
            createdAt: now,
            updatedAt: now,
            viewport: Viewport(offsetX: 0, offsetY: 0, zoom: 1.0),
            entries: [:],
            zOrder: [],
            chat: ChatThread(id: UUID(), messages: []),
            chatSettings: ChatSettings.defaultSettings,
            chatHistory: [],
            pendingClarification: nil,
            memories: [],
            log: [],
            ui: UIState(hud: hud, panels: panels),
        )
    }
}

struct PendingClarification: Codable {
    var originalText: String
    var originalImages: [ImageRef]
    var originalFiles: [FileRef]
    var question: String
    var createdAt: Double

    private enum CodingKeys: String, CodingKey {
        case originalText
        case originalImage
        case originalImages
        case question
        case createdAt
        case originalFiles
    }

    init(originalText: String, originalImages: [ImageRef], originalFiles: [FileRef], question: String, createdAt: Double) {
        self.originalText = originalText
        self.originalImages = originalImages
        self.originalFiles = originalFiles
        self.question = question
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalText = try container.decode(String.self, forKey: .originalText)
        question = try container.decode(String.self, forKey: .question)
        createdAt = try container.decode(Double.self, forKey: .createdAt)
        if let images = try container.decodeIfPresent([ImageRef].self, forKey: .originalImages) {
            originalImages = images
        } else if let image = try container.decodeIfPresent(ImageRef.self, forKey: .originalImage) {
            originalImages = [image]
        } else {
            originalImages = []
        }
        originalFiles = try container.decodeIfPresent([FileRef].self, forKey: .originalFiles) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalText, forKey: .originalText)
        try container.encode(question, forKey: .question)
        try container.encode(createdAt, forKey: .createdAt)
        if !originalImages.isEmpty {
            try container.encode(originalImages, forKey: .originalImages)
        }
        if !originalFiles.isEmpty {
            try container.encode(originalFiles, forKey: .originalFiles)
        }
    }
}

// MARK: - Routing / orchestration models

struct Clarifier: Codable, Hashable {
    let question: String
    let answer: String
}

struct RoutedContextItem: Decodable, Hashable {
    let id: String
    let excerpt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case excerpt
    }

    init(id: String, excerpt: String) {
        self.id = id
        self.excerpt = excerpt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        excerpt = (try? container.decode(String.self, forKey: .excerpt)) ?? ""
    }
}

struct ReminderActionPayload: Decodable, Hashable {
    struct Schedule: Decodable, Hashable {
        /// "once", "hourly", "daily", "weekly", "monthly", "yearly"
        let type: String?
        /// ISO8601 string. Example: "2026-01-10T09:00:00-06:00"
        let at: String?
        /// Only for weekly
        let weekdays: [String]?
        /// Optional, default 1
        let interval: Int?
    }

    let title: String?
    let work: String?
    let schedule: Schedule?
    let targetId: String?
    let query: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case work
        case schedule
        case targetId = "target_id"
        case query
    }
}

// MARK: - Notes actions (create/edit/delete/move)

struct NotesPath: Decodable, Hashable {
    // Prefer IDs when possible (deterministic).
    var stackID: UUID?
    var notebookID: UUID?
    var sectionID: UUID?

    // Optional title-based targeting (fallback).
    var stackTitle: String?
    var notebookTitle: String?
    var sectionTitle: String?

    // Optional behavior: if title-based target doesn't exist, create it.
    var createIfMissing: Bool?

    private enum CodingKeys: String, CodingKey {
        case stackID = "stack_id"
        case notebookID = "notebook_id"
        case sectionID = "section_id"
        case stackTitle = "stack_title"
        case notebookTitle = "notebook_title"
        case sectionTitle = "section_title"
        case createIfMissing = "create_if_missing"
    }
}

struct NoteBodyEdit: Decodable, Hashable {
    /// "replace_all" | "append" | "prepend" | "find_replace"
    var op: String
    var text: String?
    var find: String?
    var replace: String?

    private enum CodingKeys: String, CodingKey {
        case op
        case text
        case find
        case replace
    }
}

struct NotesActionPayload: Decodable, Hashable {
    /// "create" | "update" | "delete" | "move"
    var op: String

    // Targets
    var noteID: UUID?
    var from: NotesPath?
    var to: NotesPath?

    // Content changes
    var title: String?
    var body: String?
    var bodyEdits: [NoteBodyEdit]?

    // Response behavior
    var selectAfter: Bool?

    private enum CodingKeys: String, CodingKey {
        case op
        case noteID = "note_id"
        case from
        case to
        case title
        case body
        case bodyEdits = "body_edits"
        case selectAfter = "select_after"
    }
}

struct RoutedActionStep: Decodable, Hashable {
    let step: Int
    let actionType: String
    let relevantBoard: [RoutedContextItem]
    let relevantMemory: [RoutedContextItem]
    let relevantChat: [RoutedContextItem]
    let routerNotes: String?
    let searchQueries: [String]
    let searchQuery: String?
    let reminder: ReminderActionPayload?

    private enum CodingKeys: String, CodingKey {
        case step
        case actionType = "action_type"
        case actionTypeAlt = "actionType"
        case relevantBoard = "relevant_board"
        case relevantMemory = "relevant_memory"
        case relevantChat = "relevant_chat"
        case relevantChatAlt = "relevantChat"
        case routerNotes = "router_notes"
        case searchQueries = "search_queries"
        case searchQueriesAlt = "queries"
        case searchQuery = "search_query"
        case searchQueryAlt = "query"
        case reminder
    }

    init(step: Int,
         actionType: String,
         relevantBoard: [RoutedContextItem],
         relevantMemory: [RoutedContextItem],
         relevantChat: [RoutedContextItem] = [],
         routerNotes: String? = nil,
         searchQueries: [String] = [],
         searchQuery: String? = nil,
         reminder: ReminderActionPayload? = nil) {
        self.step = step
        self.actionType = actionType
        self.relevantBoard = relevantBoard
        self.relevantMemory = relevantMemory
        self.relevantChat = relevantChat
        self.routerNotes = routerNotes
        self.searchQueries = searchQueries
        self.searchQuery = searchQuery
        self.reminder = reminder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        step = (try? container.decode(Int.self, forKey: .step)) ?? 0
        actionType = (try? container.decode(String.self, forKey: .actionType))
            ?? (try? container.decode(String.self, forKey: .actionTypeAlt))
            ?? ""
        relevantBoard = (try? container.decode([RoutedContextItem].self, forKey: .relevantBoard)) ?? []
        relevantMemory = (try? container.decode([RoutedContextItem].self, forKey: .relevantMemory)) ?? []
        relevantChat =
            (try? container.decode([RoutedContextItem].self, forKey: .relevantChat)) ??
            (try? container.decode([RoutedContextItem].self, forKey: .relevantChatAlt)) ??
            []
        routerNotes = try? container.decode(String.self, forKey: .routerNotes)
        searchQueries =
            (try? container.decode([String].self, forKey: .searchQueries)) ??
            (try? container.decode([String].self, forKey: .searchQueriesAlt)) ??
            []
        searchQuery =
            (try? container.decode(String.self, forKey: .searchQuery)) ??
            (try? container.decode(String.self, forKey: .searchQueryAlt))
        reminder = try? container.decode(ReminderActionPayload.self, forKey: .reminder)
    }
}

struct OrchestrationRequest: Decodable, Hashable {
    let type: String
    let originalUserMessage: String
    let clarifiers: [Clarifier]
    let notesFromRouter: String?
    let actionPlan: [RoutedActionStep]

    private enum CodingKeys: String, CodingKey {
        case type
        case originalUserMessage = "original_user_message"
        case clarifiers
        case notesFromRouter = "notes_from_router"
        case actionPlan = "action_plan"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        originalUserMessage = (try? container.decode(String.self, forKey: .originalUserMessage)) ?? ""
        clarifiers = (try? container.decode([Clarifier].self, forKey: .clarifiers)) ?? []
        notesFromRouter = try? container.decode(String.self, forKey: .notesFromRouter)
        actionPlan = (try? container.decode([RoutedActionStep].self, forKey: .actionPlan)) ?? []
    }

    init(type: String,
         originalUserMessage: String,
         clarifiers: [Clarifier],
         notesFromRouter: String? = nil,
         actionPlan: [RoutedActionStep]) {
        self.type = type
        self.originalUserMessage = originalUserMessage
        self.clarifiers = clarifiers
        self.notesFromRouter = notesFromRouter
        self.actionPlan = actionPlan
    }
}
