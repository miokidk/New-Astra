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
    var userName: String
    var notes: String
    var voice: String
    var alwaysListening: Bool
    var visionDebug: Bool
    var memories: [Memory]
    var log: [LogItem]
    var chatHistory: [ChatThread]
    var reminders: [ReminderItem]

    static let `default` = AppGlobalSettings(
        userName: "",
        notes: "",
        voice: ChatSettings.defaultVoice,
        alwaysListening: ChatSettings.defaultAlwaysListening,
        visionDebug: ChatSettings.defaultVisionDebug,
        memories: [],
        log: [],
        chatHistory: [],
        reminders: []
    )

    private enum CodingKeys: String, CodingKey {
        case userName, notes, voice, alwaysListening, visionDebug, memories, log, chatHistory, reminders
    }

    init(userName: String,
         notes: String,
         voice: String,
         alwaysListening: Bool,
         visionDebug: Bool,
         memories: [Memory],
         log: [LogItem],
         chatHistory: [ChatThread],
         reminders: [ReminderItem]) {
        self.userName = userName
        self.notes = notes
        self.voice = voice
        self.alwaysListening = alwaysListening
        self.visionDebug = visionDebug
        self.memories = memories
        self.log = log
        self.chatHistory = chatHistory
        self.reminders = reminders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        if notes.isEmpty {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            notes = (try legacy.decodeIfPresent(String.self, forKey: .personality)) ?? notes
        }
        let rawVoice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ChatSettings.defaultVoice
        voice = ChatSettings.availableVoices.contains(rawVoice) ? rawVoice : ChatSettings.defaultVoice
        alwaysListening = try c.decodeIfPresent(Bool.self, forKey: .alwaysListening) ?? ChatSettings.defaultAlwaysListening
        visionDebug = try c.decodeIfPresent(Bool.self, forKey: .visionDebug) ?? ChatSettings.defaultVisionDebug
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

    private enum LegacyCodingKeys: String, CodingKey {
        case personality
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
        waitForUbiquitousItemIfNeeded(at: url, timeout: 1.0)
        return try? Data(contentsOf: url)
    }

    private func ensureDownloadedIfNeeded(at url: URL) {
        guard fm.isUbiquitousItem(at: url) else { return }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if values?.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    private func isUbiquitousItemReady(at url: URL) -> Bool {
        guard fm.isUbiquitousItem(at: url) else { return true }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        let status = values?.ubiquitousItemDownloadingStatus
        return status == .current || status == .downloaded
    }

    private func waitForUbiquitousItemIfNeeded(at url: URL, timeout: TimeInterval) {
        guard fm.isUbiquitousItem(at: url) else { return }
        if isUbiquitousItemReady(at: url) { return }
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try? fm.startDownloadingUbiquitousItem(at: url)
            if isUbiquitousItemReady(at: url) { return }
            Thread.sleep(forTimeInterval: 0.1)
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
        if idx.activeBoardId == nil && idx.boards.isEmpty {
            let url = boardsIndexURL
            if fm.fileExists(atPath: url.path), !isUbiquitousItemReady(at: url) {
                waitForUbiquitousItemIfNeeded(at: url, timeout: 3.0)
                idx = loadIndex()
            }
        }

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
        doc.chatSettings.userName = globals.userName
        doc.chatSettings.notes = globals.notes
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

        let url = boardDocURL(for: id)
        if fm.fileExists(atPath: url.path) {
            if !isUbiquitousItemReady(at: url) {
                waitForUbiquitousItemIfNeeded(at: url, timeout: 3.0)
                if let doc = loadBoardDoc(id: id) {
                    setActiveBoard(id: id)
                    return doc
                }
            }
            var placeholder = BoardDoc.defaultDoc()
            placeholder.id = id
            if let meta = boardMeta(id: id) {
                placeholder.title = meta.title
            }
            return placeholder
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
