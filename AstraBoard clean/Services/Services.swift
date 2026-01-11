import Foundation
import AppKit

final class PersistenceService {
    private let fm = FileManager.default
    private let appFolderName = "AstraBoard"

    private var baseURL: URL {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = support.appendingPathComponent(appFolderName, isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private var docURL: URL { baseURL.appendingPathComponent("board.json") }
    private var assetsURL: URL {
        let url = baseURL.appendingPathComponent("Assets", isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func load() -> BoardDoc? {
        guard fm.fileExists(atPath: docURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: docURL)
            let decoder = JSONDecoder()
            return try decoder.decode(BoardDoc.self, from: data)
        } catch {
            NSLog("Failed to load board: \(error)")
            return nil
        }
    }

    func save(doc: BoardDoc) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            try data.write(to: docURL, options: [.atomic])
        } catch {
            NSLog("Failed to save board: \(error)")
        }
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
                               reasoningEffort: reasoningEffort,
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

    func search(query: String) async throws -> [SearchItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_redirect=1&no_html=1&skip_disambig=1") else {
            throw WebSearchError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw WebSearchError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WebSearchError.badStatus(http.statusCode)
        }
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
        return Array(results.prefix(5))
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
