import Foundation

// MARK: - Tool Definitions

/// Represents a tool that the AI can call
struct ToolDefinition: Codable {
    let name: String
    let description: String
    let parameters: [String: ParameterDefinition]
    
    struct ParameterDefinition: Codable {
        let type: String
        let description: String
        let required: Bool
    }
}

// MARK: - Tool Call & Response

/// A tool call requested by the AI model
struct ToolCall: Codable {
    let id: String
    let name: String
    let arguments: [String: String]
}

/// The result of executing a tool
struct ToolResponse: Codable {
    let toolCallId: String
    let result: String
    let success: Bool
    let error: String?
    
    init(toolCallId: String, result: String, success: Bool = true, error: String? = nil) {
        self.toolCallId = toolCallId
        self.result = result
        self.success = success
        self.error = error
    }
}

// MARK: - Available Tools

class ToolRegistry {
    /// All tools available to the model
    static let availableTools: [ToolDefinition] = [
        ToolDefinition(
            name: "search",
            description: "Search the internet for current information. Requires an active internet connection.",
            parameters: [
                "query": ToolDefinition.ParameterDefinition(
                    type: "string",
                    description: "The search query to look up",
                    required: true
                )
            ]
        )
    ]
    
    /// Returns a system prompt describing all available tools
    static func systemPrompt() -> String {
        """
        # TOOL USAGE INSTRUCTIONS
        
        You have access to tools that can help you answer user questions. When you need to use a tool, you MUST respond with ONLY a JSON object - no other text before or after.
        
        ## Available Tools:
        
        ### search
        Search the internet for current information. Requires internet connection.
        - Parameter: query (string, required) - The search query
        
        ## How to Use Tools:
        
        When you determine a tool is needed:
        1. Output ONLY the JSON below (no explanation, no other text)
        2. Use this EXACT format:
        
        {"tool_call":{"id":"search_1","name":"search","arguments":{"query":"your search query here"}}}
        
        ## Examples:
        
        User: "Search for news about AI"
        Assistant: {"tool_call":{"id":"search_1","name":"search","arguments":{"query":"AI news"}}}
        
        User: "What's the weather today?"
        Assistant: {"tool_call":{"id":"search_2","name":"search","arguments":{"query":"weather today"}}}
        
        User: "What is 2+2?"
        Assistant: 2+2 equals 4.
        
        ## CRITICAL RULES:
        - When using a tool, output ONLY the JSON (one line, no formatting)
        - Do NOT explain that you're using a tool
        - Do NOT say "I need to use the search tool"
        - Do NOT use markdown code blocks
        - If a tool returns an error (like no internet), tell the user clearly
        - For questions you can answer directly, respond normally without tools
        
        Remember: Either output pure JSON for a tool call, OR a normal text response. Never both.
        """
    }
}
