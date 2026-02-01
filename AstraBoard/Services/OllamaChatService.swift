import Foundation

// MARK: - Enhanced OllamaChatService with Improved Tool Support

class OllamaChatService {
    
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
        }
    }
    
    // MARK: - Stream Method with Tool Support
    
    func stream(
        model: String,
        messages: [Message],
        includeSystemPrompt: Bool = true,
        onChunk: @escaping (Chunk) async -> Void
    ) async throws {
        
        // Build API request
        var apiMessages: [[String: Any]] = []
        
        // Add system prompt with tool definitions if requested
        if includeSystemPrompt {
            apiMessages.append([
                "role": "system",
                "content": ToolRegistry.systemPrompt()
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
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true
        ]
        
        print("DEBUG: Sending request to Ollama with \(apiMessages.count) messages")
        
        // Make the API request
        guard let url = URL(string: "http://localhost:11434/api/chat") else {
            throw NSError(domain: "OllamaChatService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid API URL"
            ])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        
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
            
            do {
                let chunk = try JSONDecoder().decode(Chunk.self, from: data)
                
                // Accumulate content to detect tool calls
                if let content = chunk.message?.content {
                    print("DEBUG: Received content: \(content)")
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
                }
                
                if chunk.done == true {
                    print("DEBUG: Stream complete. Accumulated content length: \(accumulatedContent.count)")
                    if detectedToolCall == nil && !accumulatedContent.isEmpty {
                        print("DEBUG: Final content: \(accumulatedContent.prefix(200))...")
                    }
                    break
                }
            } catch {
                print("Failed to decode chunk: \(error)")
                continue
            }
        }
    }
    
    // MARK: - Tool Call Parsing (Improved)
    
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
        
        // Check internet connectivity
        guard NetworkMonitor.shared.isConnected else {
            print("DEBUG: No internet connection!")
            return ToolResponse(
                toolCallId: toolCall.id,
                result: "",
                success: false,
                error: "No internet connection available. Unable to perform search."
            )
        }
        
        print("DEBUG: Internet connected ✓")
        
        guard let query = toolCall.arguments["query"] else {
            return ToolResponse(
                toolCallId: toolCall.id,
                result: "",
                success: false,
                error: "Missing required parameter: query"
            )
        }
        
        print("DEBUG: Performing search for: \(query)")
        
        // For now, return a fake search result
        // In a real implementation, you would call an actual search API here
        let result = """
        searched
        
        Query: "\(query)"
        Status: Search completed successfully
        """
        
        print("DEBUG: Search successful!")
        
        return ToolResponse(
            toolCallId: toolCall.id,
            result: result,
            success: true,
            error: nil
        )
    }
}
