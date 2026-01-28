import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension Notification.Name {
    static let persistenceDidChange = Notification.Name("AstraBoard.PersistenceDidChange")
}

struct AppGlobalSettings: Codable {
    var apiKey: String
    var userName: String
    var personality: String
    var voice: String
    var alwaysListening: Bool
    var memories: [Memory]
    var log: [LogItem]
    var chatHistory: [ChatThread]
    var reminders: [ReminderItem]

    static let `default` = AppGlobalSettings(
        apiKey: "",
        userName: "",
        personality: "",
        voice: ChatSettings.defaultVoice,
        alwaysListening: ChatSettings.defaultAlwaysListening,
        memories: [],
        log: [],
        chatHistory: [],
        reminders: []
    )

    private enum CodingKeys: String, CodingKey {
        case apiKey, userName, personality, voice, alwaysListening, memories, log, chatHistory, reminders
    }

    init(apiKey: String,
         userName: String,
         personality: String,
         voice: String,
         alwaysListening: Bool,
         memories: [Memory],
         log: [LogItem],
         chatHistory: [ChatThread],
         reminders: [ReminderItem]) {
        self.apiKey = apiKey
        self.userName = userName
        self.personality = personality
        self.voice = voice
        self.alwaysListening = alwaysListening
        self.memories = memories
        self.log = log
        self.chatHistory = chatHistory
        self.reminders = reminders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        let rawVoice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ChatSettings.defaultVoice
        voice = ChatSettings.availableVoices.contains(rawVoice) ? rawVoice : ChatSettings.defaultVoice
        alwaysListening = try c.decodeIfPresent(Bool.self, forKey: .alwaysListening) ?? ChatSettings.defaultAlwaysListening
        if let memories = try? c.decodeIfPresent([Memory].self, forKey: .memories) {
            self.memories = memories ?? []
        } else if let oldMemories = try? c.decodeIfPresent([String].self, forKey: .memories) {
            self.memories = (oldMemories ?? []).map { Memory(text: $0) }
        } else {
            self.memories = []
        }
        log = try c.decodeIfPresent([LogItem].self, forKey: .log) ?? []
        chatHistory = try c.decodeIfPresent([ChatThread].self, forKey: .chatHistory) ?? []
        reminders = try c.decodeIfPresent([ReminderItem].self, forKey: .reminders) ?? []
    }
}

extension AppGlobalSettings {
    func stableData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

// MARK: - Multi-board persistence

struct BoardMeta: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var version: Int64
    var isDirty: Bool

    init(id: UUID,
         title: String,
         createdAt: Double,
         updatedAt: Double,
         version: Int64 = 0,
         isDirty: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.isDirty = isDirty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case version
        case isDirty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Double.self, forKey: .createdAt)
        updatedAt = try container.decode(Double.self, forKey: .updatedAt)
        version = try container.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        isDirty = try container.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
    }
}

struct BoardsIndex: Codable {
    var activeBoardId: UUID?
    var boards: [BoardMeta]
}

private final class PersistenceFilePresenter: NSObject, NSFilePresenter {
    weak var service: PersistenceService?
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(url: URL, service: PersistenceService) {
        self.presentedItemURL = url
        self.service = service
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.presentedItemOperationQueue = queue
        super.init()
    }

    func presentedSubitemDidChange(at url: URL) {
        service?.handleFileChange(at: url)
    }

    func presentedSubitemDidAppear(at url: URL) {
        service?.handleFileChange(at: url)
    }

    func presentedSubitemDidDisappear(at url: URL) {
        service?.handleFileChange(at: url)
    }

    func presentedItemDidChange() {
        guard let url = presentedItemURL else { return }
        service?.handleFileChange(at: url)
    }
}

final class PersistenceService {
    enum ChangeEvent {
        case globalSettings
        case boardsIndex
        case board(UUID)
        case assets
        case root
    }

    static let changeNotificationUserInfoKey = "event"

    private let fm = FileManager.default
    private let appFolderName = "AstraBoard"
    private let baseURL: URL
    private let localBaseURL: URL
    private var filePresenter: PersistenceFilePresenter?

    init() {
        let localBaseURL = Self.makeLocalBaseURL(appFolderName: appFolderName, fm: fm)
        let cloudURL = Self.makeICloudBaseURL(appFolderName: appFolderName, fm: fm)
        let resolvedBaseURL = cloudURL ?? localBaseURL

        self.localBaseURL = localBaseURL
        self.baseURL = resolvedBaseURL
        self.filePresenter = nil

        Self.ensureDirectory(resolvedBaseURL, fm: fm)
        if let cloudURL {
            Self.migrateLocalToICloudIfNeeded(local: localBaseURL, cloud: cloudURL, fm: fm)
        }

        let presenter = PersistenceFilePresenter(url: resolvedBaseURL, service: self)
        self.filePresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    deinit {
        if let presenter = filePresenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
    }

    private static func iCloudContainerIdentifier() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "AstraICloudContainerIdentifier") as? String
    }

    private static func makeLocalBaseURL(appFolderName: String, fm: FileManager) -> URL {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent(appFolderName, isDirectory: true)
    }

    private static func makeICloudBaseURL(appFolderName: String, fm: FileManager) -> URL? {
        guard let containerURL = fm.url(forUbiquityContainerIdentifier: iCloudContainerIdentifier()) else { return nil }
        return containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(appFolderName, isDirectory: true)
    }

    private static func ensureDirectory(_ url: URL, fm: FileManager) {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func migrateLocalToICloudIfNeeded(local: URL, cloud: URL, fm: FileManager) {
        guard fm.fileExists(atPath: local.path) else { return }
        let cloudIndex = cloud.appendingPathComponent("boards_index.json")
        let cloudGlobals = cloud.appendingPathComponent("global_settings.json")
        let cloudBoards = cloud.appendingPathComponent("Boards", isDirectory: true)
        let cloudAssets = cloud.appendingPathComponent("Assets", isDirectory: true)

        let hasCloudData =
            fm.fileExists(atPath: cloudIndex.path) ||
            fm.fileExists(atPath: cloudGlobals.path) ||
            fm.fileExists(atPath: cloudBoards.path) ||
            fm.fileExists(atPath: cloudAssets.path)
        guard !hasCloudData else { return }

        copyMissingItems(from: local, to: cloud, fm: fm)
    }

    private static func copyMissingItems(from source: URL, to destination: URL, fm: FileManager) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { return }
        ensureDirectory(destination, fm: fm)

        let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            let relativePath = item.path.replacingOccurrences(of: source.path, with: "")
            let trimmedPath = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
            let destURL = destination.appendingPathComponent(trimmedPath)

            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)
            if itemIsDir.boolValue {
                if !fm.fileExists(atPath: destURL.path) {
                    try? fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                }
            } else if !fm.fileExists(atPath: destURL.path) {
                ensureDirectory(destURL.deletingLastPathComponent(), fm: fm)
                try? fm.copyItem(at: item, to: destURL)
            }
        }
    }

    fileprivate func handleFileChange(at url: URL) {
        notifyChange(for: url)
    }

    private func notifyChange(for url: URL) {
        let normalized = url.standardizedFileURL
        if normalized == globalSettingsURL {
            postChange(.globalSettings)
            return
        }
        if normalized == boardsIndexURL {
            postChange(.boardsIndex)
            return
        }
        if normalized.path.hasPrefix(boardsURL.path) {
            let name = normalized.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: name) {
                postChange(.board(id))
            } else {
                postChange(.boardsIndex)
            }
            return
        }
        if normalized.path.hasPrefix(assetsURL.path) {
            postChange(.assets)
            return
        }
        if normalized == baseURL {
            postChange(.root)
        }
    }

    private func postChange(_ event: ChangeEvent) {
        NotificationCenter.default.post(
            name: .persistenceDidChange,
            object: self,
            userInfo: [Self.changeNotificationUserInfoKey: event]
        )
    }

    // Legacy single-board location (pre multi-board)
    private var legacyDocURL: URL { baseURL.appendingPathComponent("board.json") }
    private var globalSettingsURL: URL { baseURL.appendingPathComponent("global_settings.json") }

    // New multi-board locations
    private var boardsURL: URL {
        let url = baseURL.appendingPathComponent("Boards", isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            Self.ensureDirectory(url, fm: fm)
        }
        return url
    }

    private var boardsIndexURL: URL { baseURL.appendingPathComponent("boards_index.json") }

    private func boardDocURL(for id: UUID) -> URL {
        boardsURL.appendingPathComponent("\(id.uuidString).json")
    }

    private var assetsURL: URL {
        let url = baseURL.appendingPathComponent("Assets", isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            Self.ensureDirectory(url, fm: fm)
        }
        return url
    }

    private func readData(at url: URL) -> Data? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        if fm.isUbiquitousItem(at: url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        return try? Data(contentsOf: url)
    }

    private func ensureDownloadedIfNeeded(at url: URL) {
        guard fm.isUbiquitousItem(at: url) else { return }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if values?.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    // MARK: - Index helpers

    private func loadIndex() -> BoardsIndex {
        // Migrate legacy single-board if needed.
        if !fm.fileExists(atPath: boardsIndexURL.path),
           fm.fileExists(atPath: legacyDocURL.path) {
            if let legacy = loadLegacyDoc() {
                let idx = BoardsIndex(
                    activeBoardId: legacy.id,
                    boards: [
                        BoardMeta(id: legacy.id,
                                  title: legacy.title,
                                  createdAt: legacy.createdAt,
                                  updatedAt: legacy.updatedAt,
                                  version: 0,
                                  isDirty: true)
                    ]
                )
                saveBoardDoc(legacy)
                saveIndex(idx)
                // Leave legacy file on disk (harmless), but it will no longer be used.
                return idx
            }
        }

        guard fm.fileExists(atPath: boardsIndexURL.path) else {
            let idx = BoardsIndex(activeBoardId: nil, boards: [])
            saveIndex(idx)
            return idx
        }

        guard let data = readData(at: boardsIndexURL) else {
            return BoardsIndex(activeBoardId: nil, boards: [])
        }

        do {
            return try JSONDecoder().decode(BoardsIndex.self, from: data)
        } catch {
            NSLog("Failed to load boards index: \(error)")
            return BoardsIndex(activeBoardId: nil, boards: [])
        }
    }

    private func saveIndex(_ index: BoardsIndex) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: boardsIndexURL, options: [.atomic])
        } catch {
            NSLog("Failed to save boards index: \(error)")
        }
    }

    private func loadLegacyDoc() -> BoardDoc? {
        guard let data = readData(at: legacyDocURL) else { return nil }
        do {
            return try JSONDecoder().decode(BoardDoc.self, from: data)
        } catch {
            NSLog("Failed to load legacy board: \(error)")
            return nil
        }
    }

    private func loadBoardDoc(id: UUID) -> BoardDoc? {
        let url = boardDocURL(for: id)
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let data = readData(at: url) else { return nil }
        do {
            return try JSONDecoder().decode(BoardDoc.self, from: data)
        } catch {
            NSLog("Failed to load board \(id): \(error)")
            return nil
        }
    }

    private func saveBoardDoc(_ doc: BoardDoc) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            try data.write(to: boardDocURL(for: doc.id), options: [.atomic])
        } catch {
            NSLog("Failed to save board \(doc.id): \(error)")
        }
    }

    // MARK: - Public multi-board API

    /// Ensures at least one board exists and returns the default board id to open on launch.
    func defaultBoardId() -> UUID {
        var idx = loadIndex()

        if let active = idx.activeBoardId {
            return active
        }
        if let first = idx.boards.first?.id {
            idx.activeBoardId = first
            saveIndex(idx)
            return first
        }

        let created = createBoard(title: "Board 1")
        return created.id
    }

    func listBoards() -> [BoardMeta] {
        loadIndex().boards
    }

    func boardMeta(id: UUID) -> BoardMeta? {
        loadIndex().boards.first { $0.id == id }
    }

    func setBoardVersion(id: UUID, version: Int64) {
        updateBoardMeta(id: id) { meta in
            meta.version = version
        }
    }

    private func updateBoardMeta(id: UUID, update: (inout BoardMeta) -> Void) {
        var idx = loadIndex()
        guard let i = idx.boards.firstIndex(where: { $0.id == id }) else { return }
        var meta = idx.boards[i]
        update(&meta)
        idx.boards[i] = meta
        saveIndex(idx)
    }

    func setActiveBoard(id: UUID) {
        var idx = loadIndex()
        idx.activeBoardId = id
        saveIndex(idx)
    }

    func createBoard(title: String? = nil) -> BoardDoc {
        var idx = loadIndex()
        var doc = BoardDoc.defaultDoc()
        let globals = loadGlobalSettings()
        doc.chatSettings.apiKey = globals.apiKey
        doc.chatSettings.userName = globals.userName
        doc.chatSettings.personality = globals.personality
        doc.memories = globals.memories
        doc.log = globals.log
        doc.chatHistory = globals.chatHistory
        doc.reminders = globals.reminders

        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.title = title
        } else {
            doc.title = "Board \(idx.boards.count + 1)"
        }

        saveBoardDoc(doc)

        let meta = BoardMeta(id: doc.id,
                             title: doc.title,
                             createdAt: doc.createdAt,
                             updatedAt: doc.updatedAt,
                             version: 0,
                             isDirty: true)
        idx.boards.append(meta)
        idx.activeBoardId = doc.id
        saveIndex(idx)

        return doc
    }

    /// Deletes a board and returns the active board id after deletion (creating a new board if needed).
    func deleteBoard(id: UUID) -> UUID? {
        let url = boardDocURL(for: id)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }

        var idx = loadIndex()
        idx.boards.removeAll { $0.id == id }
        if idx.activeBoardId == id {
            idx.activeBoardId = idx.boards.first?.id
        }
        saveIndex(idx)

        if let active = idx.activeBoardId {
            return active
        }

        let created = createBoard(title: "Board 1")
        return created.id
    }

    /// Loads a board doc by id. If it doesn't exist yet, creates it and registers it in the index.
    func loadOrCreateBoard(id: UUID) -> BoardDoc {
        if let doc = loadBoardDoc(id: id) {
            setActiveBoard(id: id)
            return doc
        }

        var idx = loadIndex()
        var doc = BoardDoc.defaultDoc()
        doc.id = id
        doc.title = "Board \(idx.boards.count + 1)"

        saveBoardDoc(doc)

        if !idx.boards.contains(where: { $0.id == id }) {
            idx.boards.append(BoardMeta(id: doc.id,
                                        title: doc.title,
                                        createdAt: doc.createdAt,
                                        updatedAt: doc.updatedAt,
                                        version: 0,
                                        isDirty: true))
        }

        idx.activeBoardId = id
        saveIndex(idx)

        return doc
    }

    func loadBoardIfExists(id: UUID) -> BoardDoc? {
        loadBoardDoc(id: id)
    }
    
    func loadGlobalSettings() -> AppGlobalSettings {
        guard fm.fileExists(atPath: globalSettingsURL.path) else { return .default }
        guard let data = readData(at: globalSettingsURL) else { return .default }
        do {
            return try JSONDecoder().decode(AppGlobalSettings.self, from: data)
        } catch {
            NSLog("Failed to load global settings: \(error)")
            return .default
        }
    }

    func saveGlobalSettings(_ settings: AppGlobalSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: globalSettingsURL, options: [.atomic])
        } catch {
            NSLog("Failed to save global settings: \(error)")
        }
    }

    @discardableResult
    func save(doc: BoardDoc, markDirty: Bool = true, updateActive: Bool = true) -> Bool {
        saveBoardDoc(doc)

        var idx = loadIndex()
        var didMarkDirty = false

        if let i = idx.boards.firstIndex(where: { $0.id == doc.id }) {
            var meta = idx.boards[i]
            let updatedAtChanged = meta.updatedAt != doc.updatedAt
            meta.title = doc.title
            meta.updatedAt = doc.updatedAt
            if markDirty {
                if updatedAtChanged {
                    meta.isDirty = true
                    didMarkDirty = true
                }
            } else {
                meta.isDirty = false
            }
            idx.boards[i] = meta
        } else {
            let meta = BoardMeta(id: doc.id,
                                 title: doc.title,
                                 createdAt: doc.createdAt,
                                 updatedAt: doc.updatedAt,
                                 version: 0,
                                 isDirty: markDirty)
            idx.boards.append(meta)
            didMarkDirty = markDirty
        }
        if updateActive {
            idx.activeBoardId = doc.id
        }
        saveIndex(idx)
        return didMarkDirty
    }

    func copyImage(url: URL) -> ImageRef? {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let filename = UUID().uuidString + "." + ext
        let destination = assetsURL.appendingPathComponent(filename)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: url, to: destination)
            return ImageRef(filename: filename)
        } catch {
            NSLog("Failed to copy image: \(error)")
            return nil
        }
    }

    func saveImage(data: Data, ext: String = "png") -> ImageRef? {
        let cleanExt = ext.isEmpty ? "png" : ext
        let filename = UUID().uuidString + "." + cleanExt
        let destination = assetsURL.appendingPathComponent(filename)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try data.write(to: destination, options: [.atomic])
            return ImageRef(filename: filename)
        } catch {
            NSLog("Failed to save image: \(error)")
            return nil
        }
    }

    func imageURL(for ref: ImageRef) -> URL? {
        let url = assetsURL.appendingPathComponent(ref.filename)
        guard fm.fileExists(atPath: url.path) else { return nil }
        ensureDownloadedIfNeeded(at: url)
        return url
    }

    func copyFile(url: URL) -> FileRef? {
        let ext = url.pathExtension
        let filename = ext.isEmpty ? UUID().uuidString : UUID().uuidString + "." + ext
        let destination = assetsURL.appendingPathComponent(filename)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: url, to: destination)
            let originalName = url.lastPathComponent
            return FileRef(filename: filename, originalName: originalName)
        } catch {
            NSLog("Failed to copy file: \(error)")
            return nil
        }
    }

    func fileURL(for ref: FileRef) -> URL? {
        let url = assetsURL.appendingPathComponent(ref.filename)
        guard fm.fileExists(atPath: url.path) else { return nil }
        ensureDownloadedIfNeeded(at: url)
        return url
    }

    func assetExists(filename: String) -> Bool {
        let url = assetsURL.appendingPathComponent(filename)
        return fm.fileExists(atPath: url.path)
    }

    func assetURL(for filename: String) -> URL? {
        let url = assetsURL.appendingPathComponent(filename)
        guard fm.fileExists(atPath: url.path) else { return nil }
        ensureDownloadedIfNeeded(at: url)
        return url
    }

    @discardableResult
    func saveAsset(data: Data, filename: String) -> Bool {
        let destination = assetsURL.appendingPathComponent(filename)
        do {
            if fm.fileExists(atPath: destination.path) {
                return true
            }
            try data.write(to: destination, options: [.atomic])
            postChange(.assets)
            return true
        } catch {
            NSLog("Failed to save asset \(filename): \(error)")
            return false
        }
    }
}

final class AIService {
    struct Message: Encodable {
        struct ContentPart: Encodable {
            struct ImageURL: Encodable {
                let url: String
            }

            let type: String
            let text: String?
            let imageURL: ImageURL?

            static func text(_ value: String) -> ContentPart {
                ContentPart(type: "text", text: value, imageURL: nil)
            }

            static func image(url: String) -> ContentPart {
                ContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: url))
            }

            private enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
            }
        }

        enum Content: Encodable {
            case text(String)
            case parts([ContentPart])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let value):
                    try container.encode(value)
                case .parts(let parts):
                    try container.encode(parts)
                }
            }
        }

        let role: String
        let content: Content
    }

    enum ReasoningEffort: String, Encodable {
        case low
        case medium
        case high
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double?
        let reasoningEffort: ReasoningEffort?
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case reasoningEffort = "reasoning_effort"
            case stream
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta
        }
        let choices: [Choice]
    }

    private struct ImageRequest: Encodable {
        let model: String
        let prompt: String
        let size: String
    }

    private struct SpeechRequest: Encodable {
        let model: String
        let voice: String
        let input: String
        let responseFormat: String

        enum CodingKeys: String, CodingKey {
            case model
            case voice
            case input
            case responseFormat = "response_format"
        }
    }

    private struct ImageResponse: Decodable {
        struct ImageData: Decodable {
            let b64Json: String?
            let revisedPrompt: String?

            enum CodingKeys: String, CodingKey {
                case b64Json = "b64_json"
                case revisedPrompt = "revised_prompt"
            }
        }
        let data: [ImageData]
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }
        let error: Detail
    }

    enum AIServiceError: LocalizedError {
        case invalidResponse
        case badStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Unexpected response from OpenAI."
            case .badStatus(let code, let message):
                if message.isEmpty {
                    return "OpenAI request failed with status \(code)."
                }
                return "OpenAI request failed (\(code)): \(message)"
            }
        }
    }

    func streamChat(model: String,
                    apiKey: String,
                    messages: [Message],
                    reasoningEffort: ReasoningEffort? = nil,
                    onDelta: @escaping (String) -> Void) async throws {
        let request = try makeChatRequest(model: model,
                                          apiKey: apiKey,
                                          messages: messages,
                                          reasoningEffort: reasoningEffort)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            let message = parseErrorMessage(from: data)
            throw AIServiceError.badStatus(http.statusCode, message)
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                break
            }
            guard let data = payload.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(StreamChunk.self, from: data)
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                onDelta(delta)
            }
        }
    }

    func completeChat(model: String,
                      apiKey: String,
                      messages: [Message],
                      reasoningEffort: ReasoningEffort? = nil) async throws -> String {
        var output = ""
        try await streamChat(model: model,
                             apiKey: apiKey,
                             messages: messages,
                             reasoningEffort: reasoningEffort) { delta in
            output += delta
        }
        return output
    }

    func generateImage(model: String,
                       apiKey: String,
                       prompt: String,
                       size: String = "1024x1024") async throws -> (data: Data, revisedPrompt: String?) {
        let request = try makeImageRequest(model: model, apiKey: apiKey, prompt: prompt, size: size)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = parseErrorMessage(from: data)
            throw AIServiceError.badStatus(http.statusCode, message)
        }
        let decoded = try JSONDecoder().decode(ImageResponse.self, from: data)
        guard let first = decoded.data.first, let base64 = first.b64Json,
              let imageData = Data(base64Encoded: base64) else {
            throw AIServiceError.invalidResponse
        }
        return (imageData, first.revisedPrompt)
    }

    func editImage(model: String,
                   apiKey: String,
                   prompt: String,
                   imageData: Data,
                   imageFilename: String = "image.png",
                   imageMimeType: String = "image/png",
                   size: String = "1024x1024") async throws -> (data: Data, revisedPrompt: String?) {
        let request = try makeImageEditRequest(model: model,
                                               apiKey: apiKey,
                                               prompt: prompt,
                                               imageData: imageData,
                                               imageFilename: imageFilename,
                                               imageMimeType: imageMimeType,
                                               size: size)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = parseErrorMessage(from: data)
            throw AIServiceError.badStatus(http.statusCode, message)
        }
        let decoded = try JSONDecoder().decode(ImageResponse.self, from: data)
        guard let first = decoded.data.first, let base64 = first.b64Json,
              let imageData = Data(base64Encoded: base64) else {
            throw AIServiceError.invalidResponse
        }
        return (imageData, first.revisedPrompt)
    }

    func synthesizeSpeech(model: String,
                          apiKey: String,
                          input: String,
                          voice: String,
                          format: String = "mp3") async throws -> Data {
        let request = try makeSpeechRequest(model: model,
                                            apiKey: apiKey,
                                            input: input,
                                            voice: voice,
                                            format: format)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = parseErrorMessage(from: data)
            throw AIServiceError.badStatus(http.statusCode, message)
        }
        return data
    }

    private func makeChatRequest(model: String,
                                 apiKey: String,
                                 messages: [Message],
                                 reasoningEffort: ReasoningEffort?) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let temperature = supportsTemperature(model) ? 1.0 : nil
        let body = ChatRequest(model: model,
                               messages: messages,
                               temperature: temperature,
                               reasoningEffort: nil,   // <- IMPORTANT: don't send this on chat/completions
                               stream: true)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func makeImageRequest(model: String,
                                  apiKey: String,
                                  prompt: String,
                                  size: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            throw AIServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = ImageRequest(model: model, prompt: prompt, size: size)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func makeImageEditRequest(model: String,
                                      apiKey: String,
                                      prompt: String,
                                      imageData: Data,
                                      imageFilename: String,
                                      imageMimeType: String,
                                      size: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/images/edits") else {
            throw AIServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body = Data()
        body.appendMultipartField(name: "model", value: model, boundary: boundary)
        body.appendMultipartField(name: "prompt", value: prompt, boundary: boundary)
        body.appendMultipartField(name: "size", value: size, boundary: boundary)
        body.appendMultipartFile(name: "image",
                                 filename: imageFilename,
                                 mimeType: imageMimeType,
                                 data: imageData,
                                 boundary: boundary)
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    private func makeSpeechRequest(model: String,
                                   apiKey: String,
                                   input: String,
                                   voice: String,
                                   format: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw AIServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = SpeechRequest(model: model, voice: voice, input: input, responseFormat: format)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func supportsTemperature(_ _: String) -> Bool {
        true
    }

    private func parseErrorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class WebSearchService {
    struct SearchItem {
        let title: String
        let url: String
        let snippet: String?
    }
    
    struct PageExcerpt {
        let title: String
        let url: String
        let text: String
    }

    enum WebSearchError: LocalizedError {
        case invalidURL
        case invalidResponse
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid search URL."
            case .invalidResponse:
                return "Unexpected search response."
            case .badStatus(let code):
                return "Search request failed with status \(code)."
            }
        }
    }
    
    func fetchPageExcerpts(from items: [SearchItem], maxPages: Int = 3, maxCharsPerPage: Int = 2000) async throws -> [PageExcerpt] {
        let candidates = items.filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let picked = Array(candidates.prefix(maxPages))
        if picked.isEmpty { return [] }

        return try await withThrowingTaskGroup(of: PageExcerpt?.self) { group in
            for item in picked {
                group.addTask {
                    guard let url = URL(string: item.url) else { return nil }
                    do {
                        let text = try await self.fetchReadableText(from: url, maxChars: maxCharsPerPage)
                        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return nil }
                        return PageExcerpt(title: item.title, url: item.url, text: clean)
                    } catch {
                        return nil // skip blocked/failed pages
                    }
                }
            }

            var out: [PageExcerpt] = []
            for try await maybe in group {
                if let maybe { out.append(maybe) }
            }
            return out
        }
    }

    private func fetchReadableText(from url: URL, maxChars: Int) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebSearchError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw WebSearchError.badStatus(http.statusCode) }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let limited = data.prefix(1_500_000)

        var raw = String(data: limited, encoding: .utf8)
        if raw == nil {
            raw = String(decoding: limited, as: UTF8.self)
        }
        let htmlOrText = raw ?? ""

        let isHTML = contentType.contains("text/html") || htmlOrText.contains("<html") || htmlOrText.contains("<!doctype")
        let plain = isHTML ? Self.htmlToPlainText(htmlOrText) : htmlOrText

        let cleaned = Self.normalizeWhitespace(plain)
        if cleaned.count <= maxChars { return cleaned }
        let idx = cleaned.index(cleaned.startIndex, offsetBy: maxChars)
        return String(cleaned[..<idx])
    }

    private static func htmlToPlainText(_ html: String) -> String {
        if let data = html.data(using: .utf8) {
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            if let attributed = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
                return attributed.string
            }
        }
        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r", with: "")
        t = t.replacingOccurrences(of: "\t", with: " ")
        t = t.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(query: String) async throws -> [SearchItem] {
        let instant = try await searchDDGInstant(query: query)
        if !instant.isEmpty { return instant }

        let html = try await searchDDGHTML(query: query)
        return html
    }
    
    private func searchDDGInstant(query: String) async throws -> [SearchItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(
            string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_redirect=1&no_html=1&skip_disambig=1"
        ) else { throw WebSearchError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WebSearchError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw WebSearchError.badStatus(http.statusCode) }

        let decoded = try JSONDecoder().decode(DDGResponse.self, from: data)

        var results: [SearchItem] = []

        if let abstract = decoded.abstractText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !abstract.isEmpty {
            let heading = decoded.heading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = heading.isEmpty ? "Result" : heading
            let url = decoded.abstractURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            results.append(SearchItem(title: title, url: url, snippet: abstract))
        }

        let related = flattenRelatedTopics(decoded.relatedTopics ?? [])
        for topic in related {
            guard let text = topic.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let url = topic.firstURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { continue }
            let (title, snippet) = splitTitleAndSnippet(text)
            results.append(SearchItem(title: title, url: url, snippet: snippet))
        }

        return Array(results.prefix(10))
    }

    private func searchDDGHTML(query: String) async throws -> [SearchItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // This endpoint is more consistent than lite.duckduckgo.com for extracting results
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            throw WebSearchError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw WebSearchError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw WebSearchError.badStatus(http.statusCode) }

        let html = String(data: data, encoding: .utf8) ?? ""

        #if DEBUG
        print("DDG HTML status:", http.statusCode, "bytes:", data.count)
        if html.isEmpty { print("DDG HTML was empty string") }
        #endif

        let parsed = parseDDGHTML(html)
        return Array(parsed.prefix(10))
    }

    private func parseDDGHTML(_ html: String) -> [SearchItem] {
        // Title links: <a class="result__a" href="...">Title</a>
        let linkPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        // Snippets: <a class="result__snippet"> ... </a> OR <div class="result__snippet"> ... </div>
        let snippetPattern = #"<(?:a|div)[^>]*class="result__snippet"[^>]*>(.*?)</(?:a|div)>"#

        let linkRe = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let snipRe = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])

        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        let linkMatches = linkRe?.matches(in: html, options: [], range: fullRange) ?? []
        let snipMatches = snipRe?.matches(in: html, options: [], range: fullRange) ?? []

        func decodeHTML(_ s: String) -> String {
            let data = Data(s.utf8)
            if let attr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            ) {
                return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func decodeDDGRedirect(_ urlString: String) -> String {
            guard let comps = URLComponents(string: urlString) else { return urlString }
            let isDDGRedirect =
                (comps.host?.contains("duckduckgo.com") == true) &&
                (comps.path == "/l/" || comps.path == "/l")
            guard isDDGRedirect else { return urlString }

            let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value
            return uddg?.removingPercentEncoding ?? urlString
        }

        var results: [SearchItem] = []
        let count = min(linkMatches.count, 10)

        for i in 0..<count {
            let m = linkMatches[i]
            guard m.numberOfRanges >= 3 else { continue }

            let rawHref = ns.substring(with: m.range(at: 1))
            let rawTitle = ns.substring(with: m.range(at: 2))

            let title = decodeHTML(rawTitle)
            let url = decodeDDGRedirect(rawHref)

            var snippet: String? = nil
            if i < snipMatches.count, snipMatches[i].numberOfRanges >= 2 {
                let rawSnip = ns.substring(with: snipMatches[i].range(at: 1))
                let s = decodeHTML(rawSnip)
                if !s.isEmpty { snippet = s }
            }

            if !url.isEmpty {
                results.append(SearchItem(title: title.isEmpty ? url : title, url: url, snippet: snippet))
            }
        }

        return results
    }

    private func searchDDGLite(query: String) async throws -> [SearchItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)") else {
            throw WebSearchError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw WebSearchError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw WebSearchError.badStatus(http.statusCode) }

        let html = String(data: data, encoding: .utf8) ?? ""
        let parsed = parseDDGLiteHTML(html)
        return Array(parsed.prefix(10))
    }

    private func parseDDGLiteHTML(_ html: String) -> [SearchItem] {
        // Titles + links
        let linkPattern = #"<a[^>]*class="result-link"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        // Snippets (often present)
        let snippetPattern = #"<td[^>]*class="result-snippet"[^>]*>(.*?)</td>"#

        let linkRe = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let snipRe = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive, .dotMatchesLineSeparators])

        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        let linkMatches = linkRe?.matches(in: html, options: [], range: fullRange) ?? []
        let snipMatches = snipRe?.matches(in: html, options: [], range: fullRange) ?? []

        func decodeHTML(_ s: String) -> String {
            let data = Data(s.utf8)
            if let attr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            ) {
                return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func decodeDDGRedirect(_ urlString: String) -> String {
            guard let comps = URLComponents(string: urlString) else { return urlString }
            let isDDGRedirect = (comps.host?.contains("duckduckgo.com") == true) && comps.path == "/l/"
            guard isDDGRedirect else { return urlString }

            let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value
            return uddg?.removingPercentEncoding ?? urlString
        }

        var results: [SearchItem] = []
        let count = min(linkMatches.count, 10)

        for i in 0..<count {
            let m = linkMatches[i]
            guard m.numberOfRanges >= 3 else { continue }

            let rawHref = ns.substring(with: m.range(at: 1))
            let rawTitle = ns.substring(with: m.range(at: 2))

            let title = decodeHTML(rawTitle)
            let url = decodeDDGRedirect(rawHref)

            var snippet: String? = nil
            if i < snipMatches.count, snipMatches[i].numberOfRanges >= 2 {
                let rawSnip = ns.substring(with: snipMatches[i].range(at: 1))
                let s = decodeHTML(rawSnip)
                if !s.isEmpty { snippet = s }
            }

            if !url.isEmpty {
                results.append(SearchItem(title: title.isEmpty ? url : title, url: url, snippet: snippet))
            }
        }

        return results
    }

    private func splitTitleAndSnippet(_ text: String) -> (String, String?) {
        let separators = [" - ", " – ", " — "]
        for separator in separators {
            if let range = text.range(of: separator) {
                let title = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (title.isEmpty ? text : title, snippet.isEmpty ? nil : snippet)
            }
        }
        return (text, nil)
    }

    private func flattenRelatedTopics(_ topics: [DDGRelatedTopic]) -> [DDGRelatedTopic] {
        var flattened: [DDGRelatedTopic] = []
        for topic in topics {
            if topic.text != nil || topic.firstURL != nil {
                flattened.append(topic)
            }
            if let children = topic.topics, !children.isEmpty {
                flattened.append(contentsOf: flattenRelatedTopics(children))
            }
        }
        return flattened
    }
}

private struct DDGResponse: Decodable {
    let heading: String?
    let abstractText: String?
    let abstractURL: String?
    let relatedTopics: [DDGRelatedTopic]?

    private enum CodingKeys: String, CodingKey {
        case heading = "Heading"
        case abstractText = "AbstractText"
        case abstractURL = "AbstractURL"
        case relatedTopics = "RelatedTopics"
    }
}

private struct DDGRelatedTopic: Decodable {
    let text: String?
    let firstURL: String?
    let topics: [DDGRelatedTopic]?

    private enum CodingKeys: String, CodingKey {
        case text = "Text"
        case firstURL = "FirstURL"
        case topics = "Topics"
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        append(data)
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(name: String,
                                      filename: String,
                                      mimeType: String,
                                      data: Data,
                                      boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
