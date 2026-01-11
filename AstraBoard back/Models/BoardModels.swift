import Foundation
import CoreGraphics

enum EntryType: String, Codable {
    case text, image, file, shape, line
}

enum Actor: String, Codable {
    case user, model
}

enum ShapeKind: String, Codable {
    case rect, circle
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
        case .rect:
            return ShapeStyle(fillColor: ColorComponents(red: 0.6, green: 0.6, blue: 0.6),
                              fillOpacity: 1.0,
                              borderColor: ColorComponents(red: 0.6, green: 0.6, blue: 0.6),
                              borderOpacity: 0.0,
                              borderWidth: 0)
        case .circle:
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
    static let defaultSettings = ChatSettings(model: defaultModel, apiKey: "", personality: "", userName: "")

    var model: String
    var apiKey: String
    var personality: String
    var userName: String

    private enum CodingKeys: String, CodingKey {
        case model
        case apiKey
        case personality
        case userName
    }

    init(model: String, apiKey: String, personality: String, userName: String) {
        self.model = model
        self.apiKey = apiKey
        self.personality = personality
        self.userName = userName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        personality = try container.decode(String.self, forKey: .personality)
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(personality, forKey: .personality)
        try container.encode(userName, forKey: .userName)
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

struct Memory: Codable, Identifiable, Hashable {
    var id: UUID
    var text: String
    var image: ImageRef? // nil for text-only memories
    var createdAt: Double

    init(id: UUID = UUID(), text: String, image: ImageRef? = nil, createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.text = text
        self.image = image
        self.createdAt = createdAt
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
            ?? PanelBox(isOpen: false, x: 360, y: 140, w: 320, h: 400)
        log = try container.decode(PanelBox.self, forKey: .log)

        memories = try container.decodeIfPresent(PanelBox.self, forKey: .memories)
            ?? PanelBox(isOpen: false, x: 320, y: 200, w: 320, h: 400)

        shapeStyle = try container.decodeIfPresent(PanelBox.self, forKey: .shapeStyle)
            ?? PanelBox(isOpen: false, x: 640, y: 140, w: 280, h: 260)
        settings = try container.decodeIfPresent(PanelBox.self, forKey: .settings)
            ?? PanelBox(isOpen: false, x: 640, y: 120, w: 320, h: 220)
        personality = try container.decodeIfPresent(PanelBox.self, forKey: .personality)
            ?? PanelBox(isOpen: false, x: 640, y: 360, w: 320, h: 260)
        reminder = try container.decodeIfPresent(PanelBox.self, forKey: .reminder) // Decode new property
            ?? PanelBox(isOpen: false, x: 400, y: 100, w: 320, h: 200) // Default value for reminder panel
    }
}

struct UIState: Codable {
    static let defaultHUDBarColor = ColorComponents(red: 0.93, green: 0.9, blue: 0.98)

    var hud: FloatingBox
    var panels: PanelsState
    var hudBarColor: ColorComponents
    var hudBarOpacity: Double

    init(hud: FloatingBox,
         panels: PanelsState,
         hudBarColor: ColorComponents = UIState.defaultHUDBarColor,
         hudBarOpacity: Double = 1.0) {
        self.hud = hud
        self.panels = panels
        self.hudBarColor = hudBarColor
        self.hudBarOpacity = hudBarOpacity
    }

    private enum CodingKeys: String, CodingKey {
        case hud
        case panels
        case hudBarColor
        case hudBarOpacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hud = try container.decode(FloatingBox.self, forKey: .hud)
        panels = try container.decode(PanelsState.self, forKey: .panels)
        hudBarColor = try container.decodeIfPresent(ColorComponents.self, forKey: .hudBarColor)
            ?? UIState.defaultHUDBarColor
        hudBarOpacity = try container.decodeIfPresent(Double.self, forKey: .hudBarOpacity) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hud, forKey: .hud)
        try container.encode(panels, forKey: .panels)
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
            chat: PanelBox(isOpen: false, x: 260, y: 120, w: 320, h: 400),
            chatArchive: PanelBox(isOpen: false, x: 360, y: 140, w: 320, h: 400),
            log: PanelBox(isOpen: false, x: 300, y: 180, w: 320, h: 400),
            memories: PanelBox(isOpen: false, x: 320, y: 200, w: 320, h: 400),
            shapeStyle: PanelBox(isOpen: false, x: 640, y: 140, w: 280, h: 260),
            settings: PanelBox(isOpen: false, x: 640, y: 120, w: 320, h: 220),
            personality: PanelBox(isOpen: false, x: 640, y: 360, w: 320, h: 260),
            reminder: PanelBox(isOpen: false, x: 400, y: 100, w: 320, h: 200) // Initialize new reminder panel
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

// MARK: - Reminder routing (router -> app)

struct ReminderRouting: Decodable {
    struct Schedule: Decodable {
        /// "once", "daily", "weekly"
        let type: String? // Made optional
        /// ISO8601 string. Example: "2026-01-10T09:00:00-06:00"
        let at: String? // Made optional
        /// Only for weekly
        let weekdays: [String]?
        /// Optional, default 1
        let interval: Int?
    }

    /// "create" | "list" | "cancel"
    let action: String
    /// Used for create/cancel (fallback title match)
    let title: String?
    /// What to do at reminder time
    let work: String?
    /// Schedule block for create
    let schedule: Schedule?
    /// Used for cancel by id
    let targetId: String?
}
struct RouterDecision: Decodable {
    struct BoardSelection: Decodable {
        let selectedEntryIds: [String]
        let boardInjection: String

        private enum CodingKeys: String, CodingKey {
            case selectedEntryIds = "selected_entry_ids"
            case selectedEntries = "selected_entries"
            case boardInjection = "board_injection"
        }

        init(selectedEntryIds: [String], boardInjection: String) {
            self.selectedEntryIds = selectedEntryIds
            self.boardInjection = boardInjection
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectedEntryIds = (try? container.decode([String].self, forKey: .selectedEntryIds))
                ?? (try? container.decode([String].self, forKey: .selectedEntries))
                ?? []
            boardInjection = (try? container.decode(String.self, forKey: .boardInjection)) ?? ""
        }
    }

    let intent: [String]
    let tasks: [String: [String]]
    let complexity: String
    let needsClarification: Bool
    let clarifyingQuestion: String?
    let tellUserOnRouterFail: Bool
    let userName: String?
    let textInstruction: String?
    let boardSelection: BoardSelection
    let memorySelection: MemorySelection
    let reminder: ReminderRouting?

    private enum CodingKeys: String, CodingKey {
        case intent
        case tasks
        case complexity
        case needsClarification = "needs_clarification"
        case clarificationNeeded = "clarification_needed"
        case clarifyingQuestion = "clarifying_question"
        case clarificationQuestion = "clarification_question"
        case tellUserOnRouterFail = "tell_user_on_router_fail"
        case userName = "user's name"
        case textInstruction = "text_instruction"
        case boardSelection = "board_selection"
        case memorySelection = "memory_selection"
        case memorySelectionAlt = "memorySelection"
        case reminder
    }
    
    struct MemorySelection: Decodable {
        let selectedMemories: [String]
        let memoryInjection: String

        private enum CodingKeys: String, CodingKey {
            case selectedMemories = "selected_memories"
            case selectedMemoriesAlt = "selectedMemories"
            case memoryInjection = "memory_injection"
            case memoryInjectionAlt = "memoryInjection"
            case memorySelection = "memory_selection"
            case memorySelectionAlt = "memorySelection"
            
        }

        init(selectedMemories: [String], memoryInjection: String) {
            self.selectedMemories = selectedMemories
            self.memoryInjection = memoryInjection
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectedMemories =
                (try? container.decode([String].self, forKey: .selectedMemories)) ??
                (try? container.decode([String].self, forKey: .selectedMemoriesAlt)) ??
                []
            memoryInjection =
                (try? container.decode(String.self, forKey: .memoryInjection)) ??
                (try? container.decode(String.self, forKey: .memoryInjectionAlt)) ??
                ""
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intents = try? container.decode([String].self, forKey: .intent) {
            intent = intents
        } else if let single = try? container.decode(String.self, forKey: .intent) {
            intent = [single]
        } else {
            intent = []
        }
        tasks = (try? container.decode([String: [String]].self, forKey: .tasks)) ?? [:]
        complexity = (try? container.decode(String.self, forKey: .complexity)) ?? "simple"
        needsClarification = (try? container.decode(Bool.self, forKey: .needsClarification))
            ?? (try? container.decode(Bool.self, forKey: .clarificationNeeded))
            ?? false
        clarifyingQuestion = (try? container.decode(String.self, forKey: .clarifyingQuestion))
            ?? (try? container.decode(String.self, forKey: .clarificationQuestion))
        tellUserOnRouterFail = (try? container.decode(Bool.self, forKey: .tellUserOnRouterFail)) ?? false
        userName = try? container.decode(String.self, forKey: .userName)
        textInstruction = try? container.decode(String.self, forKey: .textInstruction)
        boardSelection = (try? container.decode(BoardSelection.self, forKey: .boardSelection)) ?? BoardSelection(selectedEntryIds: [], boardInjection: "")
        memorySelection =
            (try? container.decode(MemorySelection.self, forKey: .memorySelection)) ??
            (try? container.decode(MemorySelection.self, forKey: .memorySelectionAlt)) ??
            MemorySelection(selectedMemories: [], memoryInjection: "")
        reminder = try container.decodeIfPresent(ReminderRouting.self, forKey: .reminder)
    }
}
