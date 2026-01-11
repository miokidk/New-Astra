import Foundation
import CoreGraphics

enum EntryType: String, Codable {
    case text, image, shape, line
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

enum EntryData: Codable {
    case text(String)
    case image(ImageRef)
    case shape(ShapeKind)
    case line(LineData)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image
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

struct ChatMsg: Codable, Identifiable {
    var id: UUID
    var role: Actor
    var text: String
    var image: ImageRef?
    var ts: Double
}

struct ChatThread: Codable {
    var id: UUID
    var messages: [ChatMsg]
}

struct ChatSettings: Codable {
    static let defaultModel = "gpt-5-nano"
    static let defaultSettings = ChatSettings(model: defaultModel, apiKey: "", personality: "")

    var model: String
    var apiKey: String
    var personality: String
}

struct LogItem: Codable, Identifiable {
    var id: UUID
    var ts: Double
    var actor: Actor
    var summary: String
    var relatedEntryIds: [UUID]?
    var relatedChatId: UUID?
}

struct ThoughtItem: Codable, Identifiable {
    var id: UUID
    var ts: Double
    var summary: String
    var relatedEntryIds: [UUID]?
    var relatedChatId: UUID?
    var reasoningTokens: Int?
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
    var thoughts: PanelBox
    var shapeStyle: PanelBox
    var settings: PanelBox
    var personality: PanelBox

    private enum CodingKeys: String, CodingKey {
        case chat
        case chatArchive
        case log
        case thoughts
        case shapeStyle
        case settings
        case personality
    }

    init(chat: PanelBox, chatArchive: PanelBox, log: PanelBox, thoughts: PanelBox, shapeStyle: PanelBox, settings: PanelBox, personality: PanelBox) {
        self.chat = chat
        self.chatArchive = chatArchive
        self.log = log
        self.thoughts = thoughts
        self.shapeStyle = shapeStyle
        self.settings = settings
        self.personality = personality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chat = try container.decode(PanelBox.self, forKey: .chat)
        chatArchive = try container.decodeIfPresent(PanelBox.self, forKey: .chatArchive)
            ?? PanelBox(isOpen: false, x: 360, y: 140, w: 320, h: 400)
        log = try container.decode(PanelBox.self, forKey: .log)
        thoughts = try container.decode(PanelBox.self, forKey: .thoughts)
        shapeStyle = try container.decodeIfPresent(PanelBox.self, forKey: .shapeStyle)
            ?? PanelBox(isOpen: false, x: 640, y: 140, w: 280, h: 260)
        settings = try container.decodeIfPresent(PanelBox.self, forKey: .settings)
            ?? PanelBox(isOpen: false, x: 640, y: 120, w: 320, h: 220)
        personality = try container.decodeIfPresent(PanelBox.self, forKey: .personality)
            ?? PanelBox(isOpen: false, x: 640, y: 360, w: 320, h: 260)
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
    var log: [LogItem]
    var thoughts: [ThoughtItem]
    var ui: UIState

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
        case log
        case thoughts
        case ui
    }

    init(id: UUID,
         title: String,
         createdAt: Double,
         updatedAt: Double,
         viewport: Viewport,
         entries: [UUID: BoardEntry],
         zOrder: [UUID],
         chat: ChatThread,
         chatSettings: ChatSettings,
         chatHistory: [ChatThread],
         log: [LogItem],
         thoughts: [ThoughtItem],
         ui: UIState) {
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
        self.log = log
        self.thoughts = thoughts
        self.ui = ui
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
        log = try container.decode([LogItem].self, forKey: .log)
        thoughts = try container.decode([ThoughtItem].self, forKey: .thoughts)
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
        try container.encode(log, forKey: .log)
        try container.encode(thoughts, forKey: .thoughts)
        try container.encode(ui, forKey: .ui)
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
        case .rect, .circle:
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
        let panels = PanelsState(chat: PanelBox(isOpen: false, x: 260, y: 120, w: 320, h: 400),
                                 chatArchive: PanelBox(isOpen: false, x: 360, y: 140, w: 320, h: 400),
                                 log: PanelBox(isOpen: false, x: 300, y: 180, w: 320, h: 400),
                                 thoughts: PanelBox(isOpen: false, x: 340, y: 240, w: 320, h: 400),
                                 shapeStyle: PanelBox(isOpen: false, x: 640, y: 140, w: 280, h: 260),
                                 settings: PanelBox(isOpen: false, x: 640, y: 120, w: 320, h: 220),
                                 personality: PanelBox(isOpen: false, x: 640, y: 360, w: 320, h: 260))
        return BoardDoc(id: UUID(),
                        title: "Untitled Board",
                        createdAt: now,
                        updatedAt: now,
                        viewport: Viewport(offsetX: 0, offsetY: 0, zoom: 1.0),
                        entries: [:],
                        zOrder: [],
                        chat: ChatThread(id: UUID(), messages: []),
                        chatSettings: ChatSettings.defaultSettings,
                        chatHistory: [],
                        log: [],
                        thoughts: [],
                        ui: UIState(hud: hud, panels: panels))
    }
}
