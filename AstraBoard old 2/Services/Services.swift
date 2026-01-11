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

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double?
        let stream: Bool
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

    // MARK: - Responses API (streaming + reasoning summary)

    private struct ResponseContentPart: Encodable {
        let type: String
        let text: String?
        let image_url: String?

        static func inputText(_ text: String) -> ResponseContentPart {
            ResponseContentPart(type: "input_text", text: text, image_url: nil)
        }

        static func inputImage(url: String) -> ResponseContentPart {
            ResponseContentPart(type: "input_image", text: nil, image_url: url)
        }
    }

    private struct ResponseInputItem: Encodable {
        let role: String   // "user" | "assistant"
        let content: [ResponseContentPart]
    }

    private struct ResponseReasoning: Encodable {
        let effort: String?
        let summary: String?   // "auto" enables summaries
    }

    private struct ResponseCreateRequest: Encodable {
        let model: String
        let instructions: String?
        let input: [ResponseInputItem]
        let reasoning: ResponseReasoning?
        let max_output_tokens: Int?
        let stream: Bool
    }

    private struct SSEUsage: Decodable {
        struct OutputTokensDetails: Decodable {
            let reasoning_tokens: Int?
        }
        let output_tokens_details: OutputTokensDetails?
    }

    private struct SSEResponse: Decodable {
        let usage: SSEUsage?
    }

    private struct SSEEvent: Decodable {
        let type: String
        let delta: String?
        let response: SSEResponse?
    }

    func streamChat(
        apiKey: String,
        model: String,
        systemPrompt: String,
        messages: [Message],
        onTextDelta: @escaping (String) -> Void,
        onReasoningSummaryDelta: @escaping (String) -> Void,
        onReasoningTokens: @escaping (Int?) -> Void
    ) async throws {

        let url = URL(string: "https://api.openai.com/v1/responses")!

        // Map your existing Message[] into Responses "input" items.
        // (Roles are user/assistant; image+text live together in the content array.)  [oai_citation:3‡OpenAI Platform](https://platform.openai.com/docs/guides/images-vision)
        let inputItems: [ResponseInputItem] = messages.map { msg in
            let role = (msg.role == "user") ? "user" : "assistant"
            var parts: [ResponseContentPart] = []
            if !msg.content.isEmpty {
                parts.append(.inputText(msg.content))
            }
            if let dataURL = msg.imageDataURL {
                parts.append(.inputImage(url: dataURL))
            }
            if parts.isEmpty {
                parts.append(.inputText(" "))
            }
            return ResponseInputItem(role: role, content: parts)
        }

        let body = ResponseCreateRequest(
            model: model,
            instructions: systemPrompt,
            input: inputItems,
            reasoning: ResponseReasoning(effort: nil, summary: "auto"),
            max_output_tokens: 4096,
            stream: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        // Non-200? Read the whole body and throw a useful error.
        guard http.statusCode == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw NSError(domain: "AIService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: apiError.error.message])
            }
            let fallback = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "AIService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: fallback])
        }

        // SSE loop:
        // - assistant text: response.output_text.delta  [oai_citation:4‡OpenAI Platform](https://platform.openai.com/docs/api-reference/responses-streaming)
        // - reasoning summary: response.reasoning_summary_text.delta  [oai_citation:5‡OpenAI Platform](https://platform.openai.com/docs/api-reference/responses-streaming)
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard let jsonData = payload.data(using: .utf8) else { continue }

            if let event = try? JSONDecoder().decode(SSEEvent.self, from: jsonData) {
                switch event.type {
                case "response.output_text.delta":
                    if let d = event.delta { onTextDelta(d) }
                case "response.reasoning_summary_text.delta":
                    if let d = event.delta { onReasoningSummaryDelta(d) }
                case "response.completed":
                    let tokens = event.response?.usage?.output_tokens_details?.reasoning_tokens
                    onReasoningTokens(tokens)
                default:
                    break
                }
            }
        }
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

    private func makeChatRequest(model: String, apiKey: String, messages: [Message]) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw AIServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let temperature = supportsTemperature(model) ? 1.0 : nil
        let body = ChatRequest(model: model, messages: messages, temperature: temperature, stream: true)
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

    private func supportsTemperature(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized != "gpt-5-nano"
    }

    private func parseErrorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
