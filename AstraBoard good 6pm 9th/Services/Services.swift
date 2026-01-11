import Foundation
import AppKit

struct AppGlobalSettings: Codable {
    var apiKey: String
    var userName: String
    var personality: String
    var memories: [String]
    var log: [LogItem]

    static let `default` = AppGlobalSettings(
        apiKey: "",
        userName: "",
        personality: "",
        memories: [],
        log: []
    )

    private enum CodingKeys: String, CodingKey {
        case apiKey, userName, personality, memories, log
    }

    init(apiKey: String, userName: String, personality: String, memories: [String], log: [LogItem]) {
        self.apiKey = apiKey
        self.userName = userName
        self.personality = personality
        self.memories = memories
        self.log = log
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        self.personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        self.memories = try c.decodeIfPresent([String].self, forKey: .memories) ?? []
        self.log = try c.decodeIfPresent([LogItem].self, forKey: .log) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(userName, forKey: .userName)
        try c.encode(personality, forKey: .personality)
        try c.encode(memories, forKey: .memories)
        try c.encode(log, forKey: .log)
    }
}

// MARK: - Multi-board persistence

struct BoardMeta: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Double
    var updatedAt: Double
}

struct BoardsIndex: Codable {
    var activeBoardId: UUID?
    var boards: [BoardMeta]
}

final class PersistenceService {
    private let fm = FileManager.default
    private let appFolderName = "AstraBoard"

    private var baseURL: URL {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = support.appendingPathComponent(appFolderName, isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    // Legacy single-board location (pre multi-board)
    private var legacyDocURL: URL { baseURL.appendingPathComponent("board.json") }
    private var globalSettingsURL: URL { baseURL.appendingPathComponent("global_settings.json") }

    // New multi-board locations
    private var boardsURL: URL {
        let url = baseURL.appendingPathComponent("Boards", isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
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
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
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
                                  updatedAt: legacy.updatedAt)
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

        do {
            let data = try Data(contentsOf: boardsIndexURL)
            return try JSONDecoder().decode(BoardsIndex.self, from: data)
        } catch {
            NSLog("Failed to load boards index: \(error)")
            let idx = BoardsIndex(activeBoardId: nil, boards: [])
            saveIndex(idx)
            return idx
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
        do {
            let data = try Data(contentsOf: legacyDocURL)
            return try JSONDecoder().decode(BoardDoc.self, from: data)
        } catch {
            NSLog("Failed to load legacy board: \(error)")
            return nil
        }
    }

    private func loadBoardDoc(id: UUID) -> BoardDoc? {
        let url = boardDocURL(for: id)
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
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

        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.title = title
        } else {
            doc.title = "Board \(idx.boards.count + 1)"
        }

        saveBoardDoc(doc)

        let meta = BoardMeta(id: doc.id, title: doc.title, createdAt: doc.createdAt, updatedAt: doc.updatedAt)
        idx.boards.append(meta)
        idx.activeBoardId = doc.id
        saveIndex(idx)

        return doc
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
            idx.boards.append(BoardMeta(id: doc.id, title: doc.title, createdAt: doc.createdAt, updatedAt: doc.updatedAt))
        }

        idx.activeBoardId = id
        saveIndex(idx)

        return doc
    }
    
    func loadGlobalSettings() -> AppGlobalSettings {
        guard fm.fileExists(atPath: globalSettingsURL.path) else { return .default }
        do {
            let data = try Data(contentsOf: globalSettingsURL)
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

    func save(doc: BoardDoc) {
        saveBoardDoc(doc)

        var idx = loadIndex()
        if let i = idx.boards.firstIndex(where: { $0.id == doc.id }) {
            idx.boards[i].title = doc.title
            idx.boards[i].updatedAt = doc.updatedAt
        } else {
            idx.boards.append(BoardMeta(id: doc.id, title: doc.title, createdAt: doc.createdAt, updatedAt: doc.updatedAt))
        }
        idx.activeBoardId = doc.id
        saveIndex(idx)
    }

    func export(doc: BoardDoc) {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = "AstraBoard.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(doc)
                try data.write(to: url)
            } catch {
                NSLog("Export failed: \(error)")
            }
        }
    }

    func importDoc() -> BoardDoc? {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            var doc = try decoder.decode(BoardDoc.self, from: data)
            doc.updatedAt = Date().timeIntervalSince1970
            return doc
        } catch {
            NSLog("Import failed: \(error)")
            return nil
        }
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
        return fm.fileExists(atPath: url.path) ? url : nil
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
        return fm.fileExists(atPath: url.path) ? url : nil
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
