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
struct ToolResponse: Codable, Sendable {
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
            description: "Search the internet for current information. This tool runs asynchronously - you should acknowledge the search to the user immediately, then the results will be provided to you automatically.",
            parameters: [
                "query": ToolDefinition.ParameterDefinition(
                    type: "string",
                    description: "The search query to look up",
                    required: true
                ),
                "max_results": ToolDefinition.ParameterDefinition(
                    type: "integer",
                    description: "Max number of results to return (default 6, max 20)",
                    required: false
                ),
                "acknowledgment": ToolDefinition.ParameterDefinition(
                    type: "string",
                    description: "A brief, natural message to tell the user you're searching (e.g., 'Let me look that up for you', 'I'll search for that', 'Looking into that now'). Keep it conversational and varied.",
                    required: true
                )
            ]
        )
    ]
    
    /// Returns a system prompt describing all available tools
    static func systemPrompt() -> String {
        """
        # TOOL USAGE INSTRUCTIONS

        ## PRIORITY
        The System Instructions (from the Modelfile) are the highest priority for behavior and style.
        If any tool instruction conflicts with the System Instructions, follow the System Instructions.
        When you choose to call a tool, the tool-call JSON format is mandatory.
        
        You have access to tools that can help you answer user questions. The search tool works asynchronously - when you use it, you'll immediately respond to the user with an acknowledgment, then continue the conversation while search results are being fetched in the background.
        
        ## Available Tools:
        
        ### search (ASYNC)
        Search the internet for current information. When you call this tool:
        1. You MUST provide an "acknowledgment" message that will be shown to the user immediately
        2. The search happens in the background
        3. Results will be automatically provided to you
        4. You can then respond with the information
        
        Parameters:
        - query (string, required) - The search query
        - max_results (integer, optional) - Max number of results (default 6, max 20)
        - acknowledgment (string, required) - Brief message to user (e.g., "Let me search for that", "I'll look that up")
        
        ## How to Use the Search Tool:
        
        When you need to search, output ONLY this JSON format (no other text):
        
        {"tool_call":{"id":"search_1","name":"search","arguments":{"query":"your search query","acknowledgment":"Let me look that up for you"}}}
        
        ## Examples:
        
        User: "What's the latest news about AI?"
        Assistant: {"tool_call":{"id":"search_1","name":"search","arguments":{"query":"latest AI news","acknowledgment":"I'll search for the latest AI news for you"}}}
        
        User: "What's the weather today?"
        Assistant: {"tool_call":{"id":"search_2","name":"search","arguments":{"query":"weather today","acknowledgment":"Let me check the weather"}}}
        
        User: "What is 2+2?"
        Assistant: 2+2 equals 4.
        
        ## CRITICAL RULES:
        - ALWAYS include an "acknowledgment" parameter when using search
        - Keep acknowledgments natural, brief, and conversational
        - Vary your acknowledgments - don't use the same phrase repeatedly
        - When using a tool, output ONLY the JSON (one line, no formatting)
        - Do NOT explain that you're using a tool beyond the acknowledgment
        - Do NOT use markdown code blocks for tool calls
        - For questions you can answer directly, respond according to the System Instructions without tools
        - After receiving search results, provide a helpful answer based on the information
        
        Remember: The search tool is asynchronous. Your acknowledgment will be shown immediately, then results will follow.
        """
    }
}

extension ToolDefinition {
    /// Converts ToolDefinition into the `tools` payload format expected by Ollama's /api/chat
    /// (OpenAI-style function tools).
    func asOllamaToolDict() -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []

        for (name, param) in parameters {
            properties[name] = [
                "type": param.type,
                "description": param.description
            ]
            if param.required {
                required.append(name)
            }
        }

        var paramsSchema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty {
            paramsSchema["required"] = required
        }

        return [
            "type": "function",
            "function": [
                "name": self.name,
                "description": self.description,
                "parameters": paramsSchema
            ]
        ]
    }
}
