import Foundation
import CoreGraphics

enum EntryType: String, Codable {
    case text, image, file, shape, line
}

enum Actor: String, Codable {
    case user
    case assistant

    /// The label shown in the chat UI.
    var chatDisplayName: String {
        switch self {
        case .assistant:
            return "Assistant"
        case .user:
            return "You"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Actor.user.rawValue
        self = Actor(rawValue: rawValue) ?? .user
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
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
    var cornerRadius: Double

    init(fillColor: ColorComponents,
         fillOpacity: Double,
         borderColor: ColorComponents,
         borderOpacity: Double,
         borderWidth: Double,
         cornerRadius: Double = 0) {
        self.fillColor = fillColor
        self.fillOpacity = fillOpacity
        self.borderColor = borderColor
        self.borderOpacity = borderOpacity
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
    }

    private enum CodingKeys: String, CodingKey {
        case fillColor
        case fillOpacity
        case borderColor
        case borderOpacity
        case borderWidth
        case cornerRadius
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fillColor = try c.decode(ColorComponents.self, forKey: .fillColor)
        fillOpacity = try c.decode(Double.self, forKey: .fillOpacity)
        borderColor = try c.decode(ColorComponents.self, forKey: .borderColor)
        borderOpacity = try c.decode(Double.self, forKey: .borderOpacity)
        borderWidth = try c.decode(Double.self, forKey: .borderWidth)

        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fillColor, forKey: .fillColor)
        try c.encode(fillOpacity, forKey: .fillOpacity)
        try c.encode(borderColor, forKey: .borderColor)
        try c.encode(borderOpacity, forKey: .borderOpacity)
        try c.encode(borderWidth, forKey: .borderWidth)
        try c.encode(cornerRadius, forKey: .cornerRadius)
    }

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

// MARK: - Image Crop

/// Normalized insets (0...1) applied to the underlying image.
/// For example, `left = 0.1` removes 10% of the image width from the left side.
struct ImageCropInsets: Codable, Hashable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double

    static let none = ImageCropInsets(left: 0, top: 0, right: 0, bottom: 0)

    func clamped() -> ImageCropInsets {
        // Prevent negative values.
        var l = max(0, left)
        var t = max(0, top)
        var r = max(0, right)
        var b = max(0, bottom)

        // Prevent fully collapsing the crop rect.
        let maxSum = 0.98
        if (l + r) > maxSum {
            let overflow = (l + r) - maxSum
            let half = overflow / 2
            l = max(0, l - half)
            r = max(0, r - half)
        }
        if (t + b) > maxSum {
            let overflow = (t + b) - maxSum
            let half = overflow / 2
            t = max(0, t - half)
            b = max(0, b - half)
        }

        // Final clamp.
        l = min(maxSum, l)
        r = min(maxSum, r)
        t = min(maxSum, t)
        b = min(maxSum, b)

        return ImageCropInsets(left: l, top: t, right: r, bottom: b)
    }
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
    var groupID: UUID?
    var type: EntryType
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var imageCrop: ImageCropInsets?
    var locked: Bool
    var createdBy: Actor
    var createdAt: Double
    var updatedAt: Double
    var data: EntryData
    var shapeStyle: ShapeStyle?
    var textStyle: TextStyle?
}

struct ChatMsg: Codable, Identifiable {
    var id: UUID
    var role: Actor
    var text: String
    var images: [ImageRef]
    var files: [FileRef]
    var toolResults: [ToolResponse]?
    var ts: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case image
        case images
        case ts
        case files
        case toolResults
    }

    init(id: UUID,
         role: Actor,
         text: String,
         images: [ImageRef],
         files: [FileRef],
         toolResults: [ToolResponse]? = nil,
         ts: Double) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.files = files
        self.toolResults = toolResults
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
        toolResults = try container.decodeIfPresent([ToolResponse].self, forKey: .toolResults)
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
        if let toolResults, !toolResults.isEmpty {
            try container.encode(toolResults, forKey: .toolResults)
        }
    }
}

struct ChatThread: Codable {
    var id: UUID
    var messages: [ChatMsg]
    var title: String?
    var contextSummaries: [String]
    var summarizedMessageCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, messages, title, contextSummaries, summarizedMessageCount
    }

    init(id: UUID,
         messages: [ChatMsg],
         title: String? = nil,
         contextSummaries: [String] = [],
         summarizedMessageCount: Int = 0) {
        self.id = id
        self.messages = messages
        self.title = title
        self.contextSummaries = contextSummaries
        self.summarizedMessageCount = summarizedMessageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        messages = try container.decode([ChatMsg].self, forKey: .messages)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        contextSummaries = try container.decodeIfPresent([String].self, forKey: .contextSummaries) ?? []
        summarizedMessageCount = try container.decodeIfPresent(Int.self, forKey: .summarizedMessageCount) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(messages, forKey: .messages)
        try container.encode(title, forKey: .title)
        if !contextSummaries.isEmpty {
            try container.encode(contextSummaries, forKey: .contextSummaries)
        }
        if summarizedMessageCount != 0 {
            try container.encode(summarizedMessageCount, forKey: .summarizedMessageCount)
        }
    }
}

struct ChatSettings: Codable {
    static let defaultVoice = "nova"
    static let defaultAlwaysListening = false
    static let defaultVisionDebug = false
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
    static let defaultSettings = ChatSettings(userName: "", notes: "")

    var userName: String
    var notes: String
    var voice: String
    var alwaysListening: Bool
    var visionDebug: Bool

    private enum CodingKeys: String, CodingKey {
        case userName
        case notes
        case voice
        case alwaysListening
        case visionDebug
    }

    init(userName: String,
         notes: String,
         voice: String = ChatSettings.defaultVoice,
         alwaysListening: Bool = ChatSettings.defaultAlwaysListening,
         visionDebug: Bool = ChatSettings.defaultVisionDebug) {
        self.userName = userName
        self.notes = notes
        self.voice = ChatSettings.availableVoices.contains(voice) ? voice : ChatSettings.defaultVoice
        self.alwaysListening = alwaysListening
        self.visionDebug = visionDebug
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        if notes.isEmpty {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            notes = (try legacy.decodeIfPresent(String.self, forKey: .personality)) ?? notes
        }
        let rawVoice = try container.decodeIfPresent(String.self, forKey: .voice) ?? Self.defaultVoice
        voice = Self.availableVoices.contains(rawVoice) ? rawVoice : Self.defaultVoice
        alwaysListening = try container.decodeIfPresent(Bool.self, forKey: .alwaysListening) ?? Self.defaultAlwaysListening
        visionDebug = try container.decodeIfPresent(Bool.self, forKey: .visionDebug) ?? Self.defaultVisionDebug
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userName, forKey: .userName)
        try container.encode(notes, forKey: .notes)
        try container.encode(voice, forKey: .voice)
        try container.encode(alwaysListening, forKey: .alwaysListening)
        try container.encode(visionDebug, forKey: .visionDebug)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case personality
    }
}

// MARK: - Reminders

struct ReminderRecurrence: Codable, Hashable {
    enum Frequency: String, Codable, Hashable {
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
    var work: String
    var dueAt: Double
    var recurrence: ReminderRecurrence?

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
    var systemInstructions: PanelBox
    var reminder: PanelBox

    private enum CodingKeys: String, CodingKey {
        case chat
        case chatArchive
        case log
        case memories
        case shapeStyle
        case settings
        case systemInstructions
        case reminder
    }

    init(
        chat: PanelBox,
        chatArchive: PanelBox,
        log: PanelBox,
        memories: PanelBox,
        shapeStyle: PanelBox,
        settings: PanelBox,
        systemInstructions: PanelBox,
        reminder: PanelBox
    ) {
        self.chat = chat
        self.chatArchive = chatArchive
        self.log = log
        self.memories = memories
        self.shapeStyle = shapeStyle
        self.settings = settings
        self.systemInstructions = systemInstructions
        self.reminder = reminder
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
            ?? PanelBox(isOpen: false, x: 600, y: 120, w: 480, h: 680)
        systemInstructions = try container.decodeIfPresent(PanelBox.self, forKey: .systemInstructions)
            ?? PanelBox(isOpen: false, x: 520, y: 120, w: 520, h: 420)
        reminder = try container.decodeIfPresent(PanelBox.self, forKey: .reminder) // Decode new property
            ?? PanelBox(isOpen: false, x: 420, y: 120, w: 360, h: 260) // Default value for reminder panel
    }
}

// MARK: - Workspace Mode

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case canvas
    case notes
    case reminders
    case calendar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .canvas: return "Canvas"
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        case .calendar: return "Calendar"
        }
    }
}

// MARK: - Calendar Workspace

enum CalendarViewMode: String, Codable, CaseIterable, Identifiable {
    case day
    case threeDays
    case week
    case month
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day:
            return "Day"
        case .threeDays:
            return "3 Days"
        case .week:
            return "Week"
        case .month:
            return "Month"
        case .year:
            return "Year"
        }
    }
}

struct CalendarEvent: Codable, Identifiable, Hashable {
    enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
        case daily
        case weekly
        case monthly
        case yearly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    struct Recurrence: Codable, Hashable {
        var frequency: RecurrenceFrequency
        var interval: Int

        init(frequency: RecurrenceFrequency, interval: Int = 1) {
            self.frequency = frequency
            self.interval = max(1, interval)
        }
    }

    var id: UUID
    var title: String
    var startAt: Double
    var endAt: Double
    var recurrence: Recurrence?

    init(
        id: UUID = UUID(),
        title: String,
        startAt: Double,
        endAt: Double,
        recurrence: Recurrence? = nil
    ) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.recurrence = recurrence
    }
}

struct CalendarWorkspace: Codable, Hashable {
    var selectedDate: Double
    var selectedView: CalendarViewMode
    var events: [CalendarEvent]

    static func `default`(now: Double = Date().timeIntervalSince1970) -> CalendarWorkspace {
        let dayStart = Calendar.current
            .startOfDay(for: Date(timeIntervalSince1970: now))
            .timeIntervalSince1970
        return CalendarWorkspace(
            selectedDate: dayStart,
            selectedView: .week,
            events: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case selectedDate
        case selectedView
        case events
    }

    init(selectedDate: Double, selectedView: CalendarViewMode, events: [CalendarEvent]) {
        self.selectedDate = selectedDate
        self.selectedView = selectedView
        self.events = events.sorted { $0.startAt < $1.startAt }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallbackDayStart = Calendar.current
            .startOfDay(for: Date())
            .timeIntervalSince1970
        selectedDate = try c.decodeIfPresent(Double.self, forKey: .selectedDate) ?? fallbackDayStart
        selectedView = try c.decodeIfPresent(CalendarViewMode.self, forKey: .selectedView) ?? .week
        events = (try c.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? [])
            .sorted { $0.startAt < $1.startAt }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedDate, forKey: .selectedDate)
        try c.encode(selectedView, forKey: .selectedView)
        try c.encode(events, forKey: .events)
    }
}

// MARK: - Reminders Workspace

struct ReminderChecklistItem: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var isCompleted: Bool
    var dueAt: Double?
    var recurrence: ReminderRecurrence?
    var createdAt: Double
    var completedAt: Double?

    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        dueAt: Double? = nil,
        recurrence: ReminderRecurrence? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        completedAt: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.dueAt = dueAt
        self.recurrence = recurrence
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

struct ReminderChecklistList: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var items: [ReminderChecklistItem]

    init(id: UUID = UUID(), title: String, items: [ReminderChecklistItem] = []) {
        self.id = id
        self.title = title
        self.items = items
    }
}

struct RemindersWorkspace: Codable, Hashable {
    var lists: [ReminderChecklistList]
    var selectedListID: UUID?

    static func `default`() -> RemindersWorkspace {
        let list = ReminderChecklistList(title: "Reminders")
        return RemindersWorkspace(lists: [list], selectedListID: list.id)
    }

    private enum CodingKeys: String, CodingKey {
        case lists
        case selectedListID
    }

    init(lists: [ReminderChecklistList], selectedListID: UUID?) {
        self.lists = lists.map { list in
            var normalized = list
            normalized.items = Self.normalizedItemOrder(normalized.items)
            return normalized
        }
        self.selectedListID = selectedListID
        self.normalizeSelection()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lists = try c.decodeIfPresent([ReminderChecklistList].self, forKey: .lists) ?? []
        selectedListID = try c.decodeIfPresent(UUID.self, forKey: .selectedListID)
        lists = lists.map { list in
            var normalized = list
            normalized.items = Self.normalizedItemOrder(normalized.items)
            return normalized
        }
        normalizeSelection()
    }

    mutating func normalizeSelection() {
        if lists.isEmpty {
            selectedListID = nil
            return
        }
        if let selectedListID,
           lists.contains(where: { $0.id == selectedListID }) {
            return
        }
        selectedListID = lists.first?.id
    }

    private static func normalizedItemOrder(_ items: [ReminderChecklistItem]) -> [ReminderChecklistItem] {
        let open = items.filter { !$0.isCompleted }
        let completed = items.filter { $0.isCompleted }
        return open + completed
    }
}

// MARK: - Notes Workspace

struct NotesSelection: Codable, Hashable {
    var areaID: UUID?
    var stackID: UUID?
    var notebookID: UUID?
    var sectionID: UUID?
    var noteID: UUID?

    init(areaID: UUID? = nil, stackID: UUID? = nil, notebookID: UUID? = nil, sectionID: UUID? = nil, noteID: UUID? = nil) {
        self.areaID = areaID
        self.stackID = stackID
        self.notebookID = notebookID
        self.sectionID = sectionID
        self.noteID = noteID
    }

    private enum CodingKeys: String, CodingKey {
        case areaID, stackID, notebookID, sectionID, noteID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedArea = try c.decodeIfPresent(UUID.self, forKey: .areaID)
        let decodedStack = try c.decodeIfPresent(UUID.self, forKey: .stackID)

        if let decodedArea {
            areaID = decodedArea
            stackID = decodedStack
        } else {
            // Legacy payloads stored the area id under stackID.
            areaID = decodedStack
            stackID = nil
        }

        notebookID = try c.decodeIfPresent(UUID.self, forKey: .notebookID)
        sectionID = try c.decodeIfPresent(UUID.self, forKey: .sectionID)
        noteID = try c.decodeIfPresent(UUID.self, forKey: .noteID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(areaID, forKey: .areaID)
        try c.encodeIfPresent(stackID, forKey: .stackID)
        try c.encodeIfPresent(notebookID, forKey: .notebookID)
        try c.encodeIfPresent(sectionID, forKey: .sectionID)
        try c.encodeIfPresent(noteID, forKey: .noteID)
    }
}

struct NoteItem: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Double
    var updatedAt: Double
    var isLocked: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, title, body, createdAt, updatedAt, isLocked
    }

    init(id: UUID, title: String, body: String, createdAt: Double, updatedAt: Double, isLocked: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isLocked = isLocked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isLocked, forKey: .isLocked)
    }
}

extension NoteItem {
    static let maxTitleLength = 30
    static let maxSidebarSnippetWords = 5
    private static let imageTokenRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\[\\[image:[^\\]]+\\]\\]", options: [])
    }()

    static func stripImageTokens(from text: String) -> String {
        guard let regex = imageTokenRegex else { return text }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let replaced = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        return replaced
    }

    var bodyTextWithoutImages: String {
        NoteItem.stripImageTokens(from: body)
    }

    /// Sidebar/Lists title: prefers `title`, otherwise uses the first few words of `body`.
    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }

        let trimmedBody = bodyTextWithoutImages.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty { return "Untitled" }

        // Collapse whitespace/newlines, take first N words.
        let normalized = trimmedBody
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let words = normalized.split(whereSeparator: { $0.isWhitespace })
        let maxWords = NoteItem.maxSidebarSnippetWords

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

struct NoteArea: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var stacks: [NoteStack]
    var notebooks: [NoteNotebook]
    var notes: [NoteItem]

    init(id: UUID, title: String, stacks: [NoteStack], notebooks: [NoteNotebook], notes: [NoteItem] = []) {
        self.id = id
        self.title = title
        self.stacks = stacks
        self.notebooks = notebooks
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case id, title, stacks, notebooks, notes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        stacks = try c.decodeIfPresent([NoteStack].self, forKey: .stacks) ?? []
        notebooks = try c.decodeIfPresent([NoteNotebook].self, forKey: .notebooks) ?? []
        notes = try c.decodeIfPresent([NoteItem].self, forKey: .notes) ?? []
    }
}

struct NotesWorkspace: Codable {
    var areas: [NoteArea]
    var selection: NotesSelection
    var sidebarCollapsed: Bool
    /// The dedicated area that holds Quick Notes. This one cannot be renamed or deleted.
    var quickNotesAreaID: UUID

    static func `default`(now: Double = Date().timeIntervalSince1970) -> NotesWorkspace {
        let quickAreaID = UUID()
        let quickArea = NoteArea(
            id: quickAreaID,
            title: "Quick Notes",
            stacks: [],
            notebooks: [],
            notes: []
        )

        return NotesWorkspace(
            areas: [quickArea],
            selection: NotesSelection(areaID: quickAreaID, stackID: nil, notebookID: nil, sectionID: nil, noteID: nil),
            sidebarCollapsed: false,
            quickNotesAreaID: quickAreaID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case areas, selection, sidebarCollapsed, quickNotesAreaID
        case stacks, quickNotesStackID
    }

    init(areas: [NoteArea], selection: NotesSelection, sidebarCollapsed: Bool, quickNotesAreaID: UUID) {
        self.areas = areas
        self.selection = selection
        self.sidebarCollapsed = sidebarCollapsed
        self.quickNotesAreaID = quickNotesAreaID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decodedAreas = try c.decodeIfPresent([NoteArea].self, forKey: .areas) ?? []
        if decodedAreas.isEmpty {
            decodedAreas = try c.decodeIfPresent([NoteArea].self, forKey: .stacks) ?? []
        }
        let decodedSelection = try c.decodeIfPresent(NotesSelection.self, forKey: .selection) ?? NotesSelection()
        let decodedCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false

        let qID = try c.decodeIfPresent(UUID.self, forKey: .quickNotesAreaID)
        let legacyQID = try c.decodeIfPresent(UUID.self, forKey: .quickNotesStackID)
        var quickID: UUID

        if let qID {
            quickID = qID
        } else if let legacyQID {
            quickID = legacyQID
        } else if let existing = decodedAreas.first(where: { $0.title == "Quick Notes" }) {
            quickID = existing.id
        } else {
            quickID = UUID()
        }

        if !decodedAreas.contains(where: { $0.id == quickID }) {
            if let existing = decodedAreas.first(where: { $0.title == "Quick Notes" }) {
                quickID = existing.id
            } else {
                let quickArea = NoteArea(id: quickID, title: "Quick Notes", stacks: [], notebooks: [], notes: [])
                decodedAreas.insert(quickArea, at: 0)
            }
        }

        var fixedSelection = decodedSelection
        if fixedSelection.areaID == nil || !decodedAreas.contains(where: { $0.id == fixedSelection.areaID }) {
            fixedSelection.areaID = quickID
            fixedSelection.stackID = nil
            fixedSelection.notebookID = nil
            fixedSelection.sectionID = nil
            fixedSelection.noteID = nil
        } else if let areaID = fixedSelection.areaID,
                  let area = decodedAreas.first(where: { $0.id == areaID }) {
            if let stackID = fixedSelection.stackID {
                if !area.stacks.contains(where: { $0.id == stackID }) {
                    fixedSelection.stackID = nil
                    fixedSelection.notebookID = nil
                    fixedSelection.sectionID = nil
                    fixedSelection.noteID = nil
                }
            } else if let notebookID = fixedSelection.notebookID {
                if !area.notebooks.contains(where: { $0.id == notebookID }) {
                    fixedSelection.notebookID = nil
                    fixedSelection.sectionID = nil
                    fixedSelection.noteID = nil
                }
            }
        }

        self.areas = decodedAreas
        self.selection = fixedSelection
        self.sidebarCollapsed = decodedCollapsed
        self.quickNotesAreaID = quickID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(areas, forKey: .areas)
        try c.encode(selection, forKey: .selection)
        try c.encode(sidebarCollapsed, forKey: .sidebarCollapsed)
        try c.encode(quickNotesAreaID, forKey: .quickNotesAreaID)
    }
}

struct UIState: Codable {
    static let defaultHUDBarColor = ColorComponents(red: 0.93, green: 0.9, blue: 0.98)

    var hud: FloatingBox
    var panels: PanelsState
    var hudBarColor: ColorComponents
    var hudBarOpacity: Double
    var workspaceMode: WorkspaceMode
    
    var activeImageCropID: UUID?

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
        self.activeImageCropID = nil
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
        activeImageCropID = nil
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
    var remindersWorkspace: RemindersWorkspace
    var notes: NotesWorkspace
    var calendar: CalendarWorkspace

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
        case remindersWorkspace
        case notes
        case calendar
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
        self.remindersWorkspace = RemindersWorkspace.default()
        self.notes = NotesWorkspace.default(now: createdAt)
        self.calendar = CalendarWorkspace.default(now: createdAt)
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
        remindersWorkspace = try container.decodeIfPresent(RemindersWorkspace.self, forKey: .remindersWorkspace)
            ?? RemindersWorkspace.default()

        notes = try container.decodeIfPresent(NotesWorkspace.self, forKey: .notes)
            ?? NotesWorkspace.default(now: createdAt)
        calendar = try container.decodeIfPresent(CalendarWorkspace.self, forKey: .calendar)
            ?? CalendarWorkspace.default(now: createdAt)

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
        try container.encode(remindersWorkspace, forKey: .remindersWorkspace)
        try container.encode(notes, forKey: .notes)
        try container.encode(calendar, forKey: .calendar)
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
            systemInstructions: PanelBox(isOpen: false, x: 520, y: 120, w: 520, h: 420),
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
            chat: ChatThread(id: UUID(), messages: [], contextSummaries: [], summarizedMessageCount: 0),
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
