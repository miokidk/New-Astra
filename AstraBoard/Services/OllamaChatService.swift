import Foundation

// MARK: - Enhanced OllamaChatService with Improved Tool Support

class OllamaChatService {
    
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    
    // MARK: - Message Structure
    
    struct Message {
        let role: String
        let content: String
        let images: [[String: String]]?
        let files: [[String: String]]?
        let toolCalls: [ToolCall]?
        let toolResults: [ToolResponse]?
        
        init(role: String,
             content: String,
             images: [[String: String]]? = nil,
             files: [[String: String]]? = nil,
             toolCalls: [ToolCall]? = nil,
             toolResults: [ToolResponse]? = nil) {
            self.role = role
            self.content = content
            self.images = images
            self.files = files
            self.toolCalls = toolCalls
            self.toolResults = toolResults
        }
    }
    
    // MARK: - Response Structures
    
    struct Chunk: Codable {
        let message: MessageChunk?
        let thinking: String?
        let done: Bool?
        let toolCall: ToolCall?
        
        struct MessageChunk: Codable {
            let role: String?
            let content: String?
            let thinking: String?
            let toolCalls: [ToolCallChunk]?

            enum CodingKeys: String, CodingKey {
                case role, content, thinking
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCallChunk: Codable {
            let id: String?
            let type: String?
            let function: FunctionChunk?

            struct FunctionChunk: Codable {
                let name: String?
                let arguments: ToolArguments?

                struct ToolArguments: Codable {
                    let rawString: String?
                    let rawObject: [String: JSONValue]?

                    init(from decoder: Decoder) throws {
                        let c = try decoder.singleValueContainer()

                        if let s = try? c.decode(String.self) {
                            rawString = s
                            rawObject = nil
                            return
                        }
                        if let o = try? c.decode([String: JSONValue].self) {
                            rawString = nil
                            rawObject = o
                            return
                        }

                        rawString = nil
                        rawObject = nil
                    }

                    func toStringDict() -> [String: String] {
                        // If Ollama gave us a real object: { "query": "..." }
                        if let rawObject {
                            return rawObject.mapValues { $0.asString() }
                        }

                        // If it gave a JSON string, try to parse it
                        if let rawString,
                           let data = rawString.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            var out: [String: String] = [:]
                            for (k, v) in obj { out[k] = String(describing: v) }
                            return out
                        }

                        // Fallback
                        if let rawString { return ["_raw": rawString] }
                        return [:]
                    }
                }
            }
        }
    }
    
    enum JSONValue: Codable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let n = try? c.decode(Double.self) { self = .number(n); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
            if let a = try? c.decode([JSONValue].self) { self = .array(a); return }

            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSONValue")
            )
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            case .object(let o): try c.encode(o)
            case .array(let a): try c.encode(a)
            case .null: try c.encodeNil()
            }
        }

        func asString() -> String {
            switch self {
            case .string(let s): return s
            case .number(let n): return String(n)
            case .bool(let b): return String(b)
            case .object, .array:
                // JSON stringify for nested structures
                if let data = try? JSONEncoder().encode(self),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
                return "\(self)"
            case .null: return "null"
            }
        }
    }
    
    // MARK: - Stream Method with Tool Support
    
    func stream(
        model: String,
        messages: [Message],
        includeSystemPrompt: Bool = true,
        includeTools: Bool = true,
        onChunk: @escaping (Chunk) async -> Void
    ) async throws {
        
        let t0 = CFAbsoluteTimeGetCurrent()
        func log(_ s: String) {
            print("TTFR(OllamaChatService) \(s) +\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")
        }
        log("stream() entered; messages=\(messages.count); includeSystemPrompt=\(includeSystemPrompt); includeTools=\(includeTools)")
        
        // Build API request
        var apiMessages: [[String: Any]] = []
        
        // Add system prompt with tool definitions if requested
        if includeSystemPrompt {
            let t_sys = CFAbsoluteTimeGetCurrent()
            let sys = ToolRegistry.systemPrompt()
            log("systemPrompt() built in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t_sys))s; chars=\(sys.count)")

            apiMessages.append([
                "role": "system",
                "content": sys
            ])
        }
        
        for message in messages {
            var messageDict: [String: Any] = [
                "role": message.role
            ]
            
            var contentText = message.content
            
            // Handle file attachments
            if let files = message.files, !files.isEmpty {
                print("DEBUG: Processing \(files.count) files")
                
                var fileContents: [String] = []
                
                for fileData in files {
                    if let filename = fileData["filename"] {
                        let mimeType = fileData["mimeType"] ?? ""
                        print("DEBUG: File: \(filename), MIME: \(mimeType)")
                        
                        // Check if it's a text-based file
                        let isTextFile = mimeType.hasPrefix("text/") ||
                                       mimeType == "application/json" ||
                                       mimeType == "application/xml" ||
                                       filename.hasSuffix(".swift") ||
                                       filename.hasSuffix(".py") ||
                                       filename.hasSuffix(".js") ||
                                       filename.hasSuffix(".ts") ||
                                       filename.hasSuffix(".java") ||
                                       filename.hasSuffix(".cpp") ||
                                       filename.hasSuffix(".c") ||
                                       filename.hasSuffix(".h") ||
                                       filename.hasSuffix(".md") ||
                                       filename.hasSuffix(".txt") ||
                                       filename.hasSuffix(".json") ||
                                       filename.hasSuffix(".xml") ||
                                       filename.hasSuffix(".html") ||
                                       filename.hasSuffix(".css")
                        
                        if isTextFile,
                           let base64 = fileData["data"],
                           let data = Data(base64Encoded: base64),
                           let text = String(data: data, encoding: .utf8) {
                            print("DEBUG: Successfully extracted \(text.count) characters")
                            
                            fileContents.append("""
                            
                            <file name="\(filename)">
                            \(text)
                            </file>
                            """)
                        } else {
                            fileContents.append("\n[Binary file: \(filename) (type: \(mimeType))]")
                        }
                    }
                }
                
                if !fileContents.isEmpty {
                    let filesSection = fileContents.joined(separator: "\n")
                    contentText = """
                    I have provided the following files for context:
                    
                    --- BEGIN FILES ---
                    \(filesSection)
                    --- END FILES ---
                    
                    User Query: \(message.content)
                    
                    Instruction: Please answer the User Query above using the provided files. Do not modify or refactor the code unless explicitly asked.
                    """
                }
            }
            
            // Handle tool results (from previous tool calls)
            if let toolResults = message.toolResults, !toolResults.isEmpty {
                var resultsText = "\n\nTool Results:\n"
                for result in toolResults {
                    resultsText += """
                    
                    Tool Call ID: \(result.toolCallId)
                    Success: \(result.success)
                    Result: \(result.result)
                    """
                    if let error = result.error {
                        resultsText += "\nError: \(error)"
                    }
                }
                contentText += resultsText
            }
            
            messageDict["content"] = contentText
            
            // Add images if present
            if let images = message.images, !images.isEmpty {
                messageDict["images"] = images.compactMap { $0["data"] }
            }
            
            apiMessages.append(messageDict)
        }
        
        let ollamaTools = ToolRegistry.availableTools.map { $0.asOllamaToolDict() }

        var requestBody: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true,
            "keep_alive": "30m"
        ]

        // Only include tools if enabled and available
        if includeTools, !ollamaTools.isEmpty {
            requestBody["tools"] = ollamaTools
        }
        
        print("DEBUG: Sending request to Ollama with \(apiMessages.count) messages")
        
        // Make the API request
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else {
            throw NSError(domain: "OllamaChatService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid API URL"
            ])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let bodySize = request.httpBody?.count ?? 0
        log("HTTP request ready; url=\(request.url?.absoluteString ?? "nil"); bodyBytes=\(bodySize)")

        let t_send = CFAbsoluteTimeGetCurrent()
        log("bytes(for:) starting...")

        let (asyncBytes, response) = try await Self.session.bytes(for: request)

        log("bytes(for:) returned (headers received) in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t_send))s")
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OllamaChatService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response"
            ])
        }
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "OllamaChatService", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP error: \(httpResponse.statusCode)"
            ])
        }
        
        // Stream the response and detect tool calls
        var accumulatedContent = ""
        var detectedToolCall: ToolCall? = nil
        
        for try await line in asyncBytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            var didLogFirstLine = false
            
            do {
                let chunk = try JSONDecoder().decode(Chunk.self, from: data)
                
                if detectedToolCall == nil,
                   let toolCalls = chunk.message?.toolCalls,
                   let first = toolCalls.first,
                   let name = first.function?.name {

                    let id = first.id ?? UUID().uuidString
                    let args = first.function?.arguments?.toStringDict() ?? [:]

                    let toolCall = ToolCall(id: id, name: name, arguments: args)
                    print("DEBUG: Tool call detected via tool_calls ✓ Name: \(name), Args: \(args)")

                    detectedToolCall = toolCall

                    await onChunk(Chunk(message: nil, thinking: nil, done: false, toolCall: toolCall))

                    // IMPORTANT: stop streaming; caller will run tool + re-prompt
                    break
                }
                
                var logBuffer = ""
                let logEveryChars = 80
                
                // Accumulate content to detect tool calls
                if let content = chunk.message?.content {
                    if !content.isEmpty {
                        logBuffer += content
                        if logBuffer.count >= logEveryChars || content.contains("\n") {
                            let cleaned = logBuffer.replacingOccurrences(of: "\n", with: "\\n")
                            print("DEBUG: Δ \(cleaned)")
                            logBuffer = ""
                        }
                    }
                    accumulatedContent += content
                    
                    // Try to parse as JSON tool call
                    if detectedToolCall == nil, let toolCall = parseToolCall(from: accumulatedContent) {
                        print("DEBUG: Tool call detected! Name: \(toolCall.name), Arguments: \(toolCall.arguments)")
                        detectedToolCall = toolCall
                        
                        // Send tool call chunk immediately
                        let toolCallChunk = Chunk(
                            message: nil,
                            thinking: nil,
                            done: false,
                            toolCall: toolCall
                        )
                        await onChunk(toolCallChunk)
                        
                        // Don't send the raw JSON as regular content
                        continue
                    }
                }
                
                // Only send content chunks if we haven't detected a tool call
                // or if there's content after the tool call
                if detectedToolCall == nil {
                    await onChunk(chunk)
                } else if chunk.done == true {
                    // Always send the done chunk
                    await onChunk(chunk)
                    if !logBuffer.isEmpty {
                        let cleaned = logBuffer.replacingOccurrences(of: "\n", with: "\\n")
                        print("DEBUG: Δ \(cleaned)")
                        logBuffer = ""
                    }
                }
                
                if chunk.done == true {
                    print("DEBUG: Stream complete. Accumulated content length: \(accumulatedContent.count)")
                    if detectedToolCall == nil && !accumulatedContent.isEmpty {
                        print("DEBUG: Final content: \(accumulatedContent.prefix(200))...")
                    }
                    break
                }
            } catch {
                print("Failed to decode chunk: \(error)\nRAW: \(line)")
                continue
            }
        }
    }
    
    // MARK: - Tool Call Parsing (Improved)
    
    private func parseToolArguments(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }

        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else { return [:] }

            var out: [String: String] = [:]
            for (k, v) in dict {
                if let s = v as? String {
                    out[k] = s
                } else {
                    // stringify anything non-string
                    out[k] = String(describing: v)
                }
            }
            return out
        } catch {
            return [:]
        }
    }
    
    private func parseToolCall(from text: String) -> ToolCall? {
        // Clean the text - remove any whitespace/newlines
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Look for JSON object containing tool_call
        // Try multiple patterns to be more flexible
        
        // Pattern 1: Standard format {"tool_call":{...}}
        if let toolCall = tryParseStandardFormat(cleanText) {
            return toolCall
        }
        
        // Pattern 2: Look for tool_call anywhere in the text
        if let toolCall = tryExtractToolCall(cleanText) {
            return toolCall
        }
        
        return nil
    }
    
    private func tryParseStandardFormat(_ text: String) -> ToolCall? {
        guard let jsonStart = text.firstIndex(of: "{"),
              let jsonEnd = text.lastIndex(of: "}") else {
            return nil
        }
        
        let jsonString = String(text[jsonStart...jsonEnd])
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        
        struct ToolCallWrapper: Codable {
            let tool_call: ToolCallData
            
            struct ToolCallData: Codable {
                let id: String
                let name: String
                let arguments: [String: String]
            }
        }
        
        if let wrapper = try? JSONDecoder().decode(ToolCallWrapper.self, from: jsonData) {
            return ToolCall(
                id: wrapper.tool_call.id,
                name: wrapper.tool_call.name,
                arguments: wrapper.tool_call.arguments
            )
        }
        
        return nil
    }
    
    private func tryExtractToolCall(_ text: String) -> ToolCall? {
        // Try to find "tool_call" and extract the object
        guard text.contains("tool_call") else { return nil }
        
        // Find the opening brace after tool_call
        guard let toolCallIndex = text.range(of: "\"tool_call\"")?.upperBound else { return nil }
        let afterToolCall = String(text[toolCallIndex...])
        
        guard let openBrace = afterToolCall.firstIndex(of: "{") else { return nil }
        
        // Find the matching closing brace
        var depth = 0
        var closeBrace: String.Index?
        
        for index in afterToolCall[openBrace...].indices {
            let char = afterToolCall[index]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    closeBrace = index
                    break
                }
            }
        }
        
        guard let closeBrace = closeBrace else { return nil }
        
        let toolCallJson = String(afterToolCall[openBrace...closeBrace])
        guard let jsonData = toolCallJson.data(using: .utf8) else { return nil }
        
        struct ToolCallData: Codable {
            let id: String
            let name: String
            let arguments: [String: String]
        }
        
        if let data = try? JSONDecoder().decode(ToolCallData.self, from: jsonData) {
            return ToolCall(
                id: data.id,
                name: data.name,
                arguments: data.arguments
            )
        }
        
        return nil
    }
}

// MARK: - Tool Executor

class ToolExecutor {
    
    /// Execute a tool call and return the result
    static func execute(_ toolCall: ToolCall) async -> ToolResponse {
        print("DEBUG: Executing tool: \(toolCall.name)")
        
        switch toolCall.name {
        case "search":
            return await executeSearch(toolCall)
        default:
            return ToolResponse(
                toolCallId: toolCall.id,
                result: "",
                success: false,
                error: "Unknown tool: \(toolCall.name)"
            )
        }
    }
    
    private static func executeSearch(_ toolCall: ToolCall) async -> ToolResponse {
        print("DEBUG: Checking internet connectivity...")

        await NetworkMonitor.shared.waitUntilReady()

        guard NetworkMonitor.shared.isConnected else {
            print("DEBUG: No internet connection!")
            return ToolResponse(
                toolCallId: toolCall.id,
                result: "",
                success: false,
                error: "No internet connection available. Unable to perform search."
            )
        }

        print("DEBUG: Internet connected ✓ (\(NetworkMonitor.shared.connectionDescription))")

        guard let query = toolCall.arguments["query"] else {
            return ToolResponse(
                toolCallId: toolCall.id,
                result: "",
                success: false,
                error: "Missing required parameter: query"
            )
        }

        print("DEBUG: Performing search for: \(query)")

        let maxResults: Int = {
            if let raw = toolCall.arguments["max_results"] {
                if let n = Int(raw) { return min(max(n, 1), 10) }
                if let d = Double(raw) { return min(max(Int(d.rounded()), 1), 10) } // handles "6.0"
            }
            return 6
        }()

        var results: [DuckDuckGoLiteSearch.SearchResult] = []
        var lastError: String?

        do {
            results = try await DuckDuckGoLiteSearch.search(query: query, maxResults: maxResults)
        } catch {
            lastError = error.localizedDescription
            print("DEBUG: DDG search failed: \(error.localizedDescription)")
        }

        if results.isEmpty {
            print("DEBUG: Search parsed 0 results (provider HTML changed or blocked).")
            return ToolResponse(
                toolCallId: toolCall.id,
                result: """
                SEARCH_RESULTS
                Query: "\(query)"
                Results: 0
                Note: No results were parsed from the search provider.
                """,
                success: true
            )
        }

        var out = """
        SEARCH_RESULTS
        Query: "\(query)"
        Results: \(results.count)

        """

        for (i, r) in results.enumerated() {
            out += """
            \(i + 1). \(r.title)
               URL: \(r.url)
               Snippet: \(r.snippet)
               Engine: \(r.engine)

            """
        }

        print("DEBUG: Search successful! Returned \(results.count) results.")
        return ToolResponse(toolCallId: toolCall.id, result: out, success: true)
    }
}

// MARK: - DuckDuckGo Lite Search (Keyless Prototype)

private enum DuckDuckGoLiteSearch {
    struct SearchResult {
        let title: String
        let url: String
        let snippet: String
        let engine: String = "duckduckgo"
    }

    static func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        // Try lite first
        if let html = try await fetchHTML(baseURL: "https://lite.duckduckgo.com/lite/", query: query) {
            print("DEBUG: DDG lite returned \(html.count) chars of HTML")
            let parsed = parseLiteHTML(html, maxResults: maxResults)
            if !parsed.isEmpty {
                print("DEBUG: DDG lite parsed \(parsed.count) results ✓")
                return parsed
            }
            // Print first 500 chars to help debug
            let preview = String(html.prefix(500))
            print("DEBUG: DDG lite HTML preview: \(preview)")
            print("DEBUG: DDG lite returned HTML but parsed 0 results — trying fallback endpoint…")
        }

        // Fallback endpoint (often more stable)
        if let html = try await fetchHTML(baseURL: "https://html.duckduckgo.com/html/", query: query) {
            print("DEBUG: DDG html returned \(html.count) chars of HTML")
            let parsed = parseLiteHTML(html, maxResults: maxResults)
            if !parsed.isEmpty {
                print("DEBUG: DDG html parsed \(parsed.count) results ✓")
                return parsed
            }
            let preview = String(html.prefix(500))
            print("DEBUG: DDG html HTML preview: \(preview)")
            print("DEBUG: DDG html fallback also parsed 0 results.")
        }

        return []
    }

    private static func fetchHTML(baseURL: String, query: String) async throws -> String? {
        var comps = URLComponents(string: baseURL)!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20  // Reduced from 25 - DDG is reliable
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "DuckDuckGoLiteSearch", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }

        let html = String(data: data, encoding: .utf8)
        if let html, !html.isEmpty { return html }
        return nil
    }

    // MARK: Parsing

    private static func parseLiteHTML(_ html: String, maxResults: Int) -> [SearchResult] {
        // DuckDuckGo Lite/HTML has evolved - try multiple patterns
        
        // Pattern 1: Modern lite format
        let pattern1 = #"<a[^>]*class=['"]result-link['"][^>]*href=['"]([^'"]+)['"][^>]*>(.*?)</a>"#
        // Pattern 2: Alternative format with result__a class
        let pattern2 = #"<a[^>]*class=['"]result__a['"][^>]*href=['"]([^'"]+)['"][^>]*>(.*?)</a>"#
        // Pattern 3: Simple href pattern as fallback
        let pattern3 = #"<a[^>]*href=['"](/[^'"]+)['"][^>]*class=['"]result[^'"]*['"][^>]*>(.*?)</a>"#
        
        var titleMatches: [[String]] = []
        
        // Try each pattern until we get results
        titleMatches = regexMatches(html, pattern: pattern1, captureGroups: 2)
        if titleMatches.isEmpty {
            titleMatches = regexMatches(html, pattern: pattern2, captureGroups: 2)
        }
        if titleMatches.isEmpty {
            titleMatches = regexMatches(html, pattern: pattern3, captureGroups: 2)
        }
        
        // Snippet patterns
        let snippetPattern1 = #"<td[^>]*class=['"]result-snippet['"][^>]*>(.*?)</td>"#
        let snippetPattern2 = #"<a[^>]*class=['"]result__snippet['"][^>]*>(.*?)</a>"#
        
        var snippetMatches = regexMatches(html, pattern: snippetPattern1, captureGroups: 1)
        if snippetMatches.isEmpty {
            snippetMatches = regexMatches(html, pattern: snippetPattern2, captureGroups: 1)
        }

        var results: [SearchResult] = []
        results.reserveCapacity(min(maxResults, titleMatches.count))

        for i in 0..<min(titleMatches.count, maxResults) {
            let rawHref = titleMatches[i][0]
            let rawTitle = titleMatches[i][1]
            let rawSnippet = (i < snippetMatches.count) ? snippetMatches[i][0] : ""

            let url = normalizeDuckDuckGoHref(rawHref)
            let title = cleanHTMLText(rawTitle)
            let snippet = cleanHTMLText(rawSnippet)

            // Skip empty results
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            
            // Skip if URL is obviously invalid
            if url.isEmpty || url == "(no url)" { continue }

            results.append(SearchResult(
                title: title,
                url: url,
                snippet: snippet.isEmpty ? "(no snippet)" : snippet
            ))
        }

        return results
    }

    private static func normalizeDuckDuckGoHref(_ href: String) -> String {
        // DDG uses various redirect formats
        var url = href.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle uddg redirect parameter
        if url.contains("uddg=") {
            let fullURL = url.hasPrefix("http") ? url : "https://lite.duckduckgo.com\(url)"
            if let parsedURL = URL(string: fullURL),
               let comps = URLComponents(url: parsedURL, resolvingAgainstBaseURL: false),
               let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
                if let decoded = uddg.removingPercentEncoding, decoded.hasPrefix("http") {
                    return decoded
                }
            }
        }
        
        // Handle relative URLs
        if url.hasPrefix("/") {
            return "https://lite.duckduckgo.com\(url)"
        }
        
        // Already absolute
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return url
        }
        
        // Default fallback
        return url.isEmpty ? "(no url)" : url
    }

    private static func regexMatches(_ text: String, pattern: String, captureGroups: Int) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        return re.matches(in: text, options: [], range: range).map { match in
            (0..<captureGroups).map { group in
                let r = match.range(at: group + 1)
                return r.location != NSNotFound ? ns.substring(with: r) : ""
            }
        }
    }

    private static func cleanHTMLText(_ input: String) -> String {
        var s = input

        // Strip tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Decode basic entities (prototype-level)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
