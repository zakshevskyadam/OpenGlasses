import Foundation

/// Supported LLM providers
enum LLMProvider: String, CaseIterable {
    case anthropic = "anthropic"
    case openai = "openai"
    case gemini = "gemini"
    case groq = "groq"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (GPT)"
        case .gemini: return "Google (Gemini)"
        case .groq: return "Groq"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    /// Whether this provider uses the OpenAI-compatible API format
    var isOpenAICompatible: Bool {
        switch self {
        case .anthropic, .gemini: return false
        case .openai, .groq, .custom: return true
        }
    }

    /// Default base URL for the provider
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .custom: return "https://api.openai.com/v1/chat/completions"
        }
    }

    /// Default model for the provider
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.0-flash"
        case .groq: return "llama-3.3-70b-versatile"
        case .custom: return "gpt-4o"
        }
    }
}

/// Unified LLM service supporting Anthropic Claude and OpenAI-compatible APIs.
/// When OpenClaw is configured, includes tool definitions so the LLM can invoke the `execute` tool.
@MainActor
class LLMService: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var activeModelName: String = Config.activeModel?.name ?? "No Model"
    @Published var toolCallStatus: ToolCallStatus = .idle

    /// Optional OpenClaw bridge for tool calling in direct mode
    var openClawBridge: OpenClawBridge?

    /// Conversation history for multi-turn context
    private var conversationHistory: [[String: Any]] = []
    private let maxHistoryTurns = 10  // Keep last 10 exchanges

    /// Maximum tool call iterations to prevent infinite loops
    private let maxToolCallIterations = 5

    /// Build the full system prompt, optionally including location and OpenClaw context
    private static func buildSystemPrompt(locationContext: String?, includeTools: Bool) -> String {
        var prompt = Config.systemPrompt
        if includeTools {
            prompt += """


            TOOLS:
            You have access to a tool called "execute" that connects you to a powerful personal assistant (OpenClaw). \
            Use it when the user asks you to take any action: send messages, search the web, manage lists, set reminders, \
            create notes, control smart home devices, or anything beyond answering a question from your knowledge. \
            Be detailed in your task description — include names, content, platforms, quantities, etc.

            IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
            - "Sure, let me add that to your shopping list." then call execute.
            - "Got it, searching for that now." then call execute.
            """
        }
        if let location = locationContext {
            prompt += "\n\nUSER LOCATION: \(location)"
        }
        return prompt
    }

    func sendMessage(_ text: String, locationContext: String? = nil, imageData: Data? = nil) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        guard let modelConfig = Config.activeModel else {
            throw LLMError.missingAPIKey("No model configured — add one in Settings")
        }

        let provider = modelConfig.llmProvider
        let includeTools = Config.isOpenClawConfigured && openClawBridge != nil
        let fullPrompt = Self.buildSystemPrompt(locationContext: locationContext, includeTools: includeTools)

        print("🤖 Using model: \(modelConfig.name) (\(modelConfig.model) via \(provider.displayName))\(includeTools ? " [OpenClaw enabled]" : "")")

        switch provider {
        case .anthropic:
            return try await sendAnthropic(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        case .gemini:
            return try await sendGemini(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        case .openai, .groq, .custom:
            return try await sendOpenAICompatible(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        }
    }

    /// Clear conversation history (e.g. when starting fresh or switching providers)
    func clearHistory() {
        conversationHistory.removeAll()
    }

    /// Refresh the published model name from Config
    func refreshActiveModel() {
        activeModelName = Config.activeModel?.name ?? "No Model"
    }

    // MARK: - Anthropic Claude

    private func sendAnthropic(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?) async throws -> String {
        // If using OAuth token, auto-refresh if expired
        let apiKey: String
        let isOAuth = config.apiKey.hasPrefix("sk-ant-oat")
        let oauthConfigured = await OAuthTokenManager.shared.isConfigured
        if isOAuth || oauthConfigured {
            apiKey = try await OAuthTokenManager.shared.getValidAccessToken()
        } else {
            apiKey = config.apiKey
        }
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey("Anthropic API key not configured")
        }

        // Add user message to history
        if let imageData = imageData {
            let base64String = imageData.base64EncodedString()
            let content: [[String: Any]] = [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64String
                    ]
                ],
                [
                    "type": "text",
                    "text": text
                ]
            ]
            conversationHistory.append(["role": "user", "content": content])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()

        for iteration in 0..<maxToolCallIterations {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Support both API keys (sk-ant-api...) and OAuth tokens (sk-ant-oat...) from Max/Pro subscriptions
            if apiKey.hasPrefix("sk-ant-oat") {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            var body: [String: Any] = [
                "model": config.model,
                "max_tokens": includeTools ? 1024 : Config.maxTokens,
                "system": systemPrompt,
                "messages": conversationHistory
            ]

            if includeTools {
                body["tools"] = ToolDeclarations.anthropicTools()
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = (errorJson["error"] as? [String: Any])?["message"] as? String {
                    print("❌ Anthropic API error \(statusCode): \(errorMsg)")
                    throw LLMError.apiError(provider: "Anthropic", statusCode: statusCode, message: errorMsg)
                }
                throw LLMError.apiError(provider: "Anthropic", statusCode: statusCode, message: nil)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else {
                throw LLMError.invalidResponse("Anthropic")
            }

            let stopReason = json["stop_reason"] as? String

            // Check for tool use blocks
            if stopReason == "tool_use", includeTools, let bridge = openClawBridge {
                // Find tool_use blocks
                var toolUseBlocks: [[String: Any]] = []
                var textParts: [String] = []

                for block in content {
                    if let type = block["type"] as? String {
                        if type == "tool_use" {
                            toolUseBlocks.append(block)
                        } else if type == "text", let t = block["text"] as? String {
                            textParts.append(t)
                        }
                    }
                }

                // Add assistant message with tool_use to history
                conversationHistory.append(["role": "assistant", "content": content] as [String: Any])

                // Execute each tool call and add results
                for toolUse in toolUseBlocks {
                    guard let toolId = toolUse["id"] as? String,
                          let input = toolUse["input"] as? [String: Any],
                          let taskDesc = input["task"] as? String else { continue }

                    print("🔧 [Anthropic] Tool call: execute(\(taskDesc.prefix(100))...)")
                    toolCallStatus = .executing("execute")

                    let result = await bridge.delegateTask(task: taskDesc, toolName: "execute")
                    toolCallStatus = result.isSuccess ? .completed("execute") : .failed("execute", "Failed")

                    let resultContent: String
                    switch result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }

                    conversationHistory.append([
                        "role": "user",
                        "content": [
                            [
                                "type": "tool_result",
                                "tool_use_id": toolId,
                                "content": resultContent
                            ]
                        ]
                    ] as [String: Any])
                }

                print("🔄 [Anthropic] Continuing after tool call (iteration \(iteration + 1))")
                continue // Loop back to get final response
            }

            // No tool calls — extract text response
            let responseText = content.compactMap { block -> String? in
                guard let type = block["type"] as? String, type == "text",
                      let text = block["text"] as? String else { return nil }
                return text
            }.joined(separator: "\n")

            guard !responseText.isEmpty else {
                throw LLMError.invalidResponse("Anthropic")
            }

            conversationHistory.append(["role": "assistant", "content": responseText])
            toolCallStatus = .idle
            return responseText
        }

        // Exhausted iterations
        toolCallStatus = .idle
        throw LLMError.invalidResponse("Anthropic (tool call loop exceeded)")
    }

    // MARK: - OpenAI-compatible

    private func sendOpenAICompatible(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?) async throws -> String {
        let provider = config.llmProvider
        let apiKey = config.apiKey
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey("\(provider.displayName) API key not configured")
        }

        var baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseURL.hasSuffix("/chat/completions") {
            if baseURL.hasSuffix("/") {
                baseURL += "chat/completions"
            } else {
                baseURL += "/chat/completions"
            }
        }
        
        guard let url = URL(string: baseURL) else {
            throw LLMError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        // Add user message to history
        // Ensure model actually supports vision if an image is provided.
        // Groq does not support vision natively through this endpoint.
        // Llama/Mistral models generally don't support OpenAI's image_url struct unless specified.
        let supportsVision = provider == .openai || config.model.lowercased().contains("vision") || config.model.lowercased().contains("gpt-4")
        
        if let imageData = imageData, supportsVision {
            let base64String = imageData.base64EncodedString()
            let content: [[String: Any]] = [
                [
                    "type": "text",
                    "text": text
                ],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64String)"
                    ]
                ]
            ]
            conversationHistory.append(["role": "user", "content": content])
        } else if imageData != nil && !supportsVision {
            // Drop the image but keep the text, and inform the model
            conversationHistory.append(["role": "user", "content": text + "\n[System note: The user attempted to send an image, but the current model (\(config.model)) does not support image analysis.]"])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()

        for iteration in 0..<maxToolCallIterations {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            // OpenAI format: system prompt is a message in the array
            var messages: [[String: Any]] = [
                ["role": "system", "content": systemPrompt]
            ]
            messages.append(contentsOf: conversationHistory)

            var body: [String: Any] = [
                "model": config.model,
                "max_tokens": includeTools ? 1024 : Config.maxTokens,
                "messages": messages
            ]

            // Only attach Tools if OpenClaw is enabled AND the provider reliably supports it.
            // Custom endpoints (Ollama/LMStudio) often crash with 400 if `tools` array is in the payload.
            let providerSupportsTools = provider == .openai || provider == .groq
            
            if includeTools && providerSupportsTools {
                body["tools"] = ToolDeclarations.openAITools()
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = errorJson["error"] as? [String: Any],
                   let errorMsg = errorObj["message"] as? String {
                    print("❌ \(provider.displayName) API error \(statusCode): \(errorMsg)")
                    throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode, message: errorMsg)
                }
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    print("❌ \(provider.displayName) error \(statusCode): \(errorMsg)")
                    throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode, message: errorMsg)
                }
                throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode, message: nil)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                throw LLMError.invalidResponse(provider.displayName)
            }

            _ = choices.first?["finish_reason"] as? String

            // Check for tool calls
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty, includeTools, let bridge = openClawBridge {
                // Add assistant message with tool_calls to history
                conversationHistory.append(message)

                for toolCall in toolCalls {
                    guard let callId = toolCall["id"] as? String,
                          let function = toolCall["function"] as? [String: Any],
                          let argsString = function["arguments"] as? String else { continue }

                    let args = (try? JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any]) ?? [:]
                    let taskDesc = args["task"] as? String ?? argsString

                    print("🔧 [OpenAI] Tool call: execute(\(taskDesc.prefix(100))...)")
                    toolCallStatus = .executing("execute")

                    let result = await bridge.delegateTask(task: taskDesc, toolName: "execute")
                    toolCallStatus = result.isSuccess ? .completed("execute") : .failed("execute", "Failed")

                    let resultContent: String
                    switch result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }

                    conversationHistory.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": resultContent
                    ])
                }

                print("🔄 [OpenAI] Continuing after tool call (iteration \(iteration + 1))")
                continue // Loop back to get final response
            }

            // No tool calls — extract text response
            guard let responseText = message["content"] as? String else {
                throw LLMError.invalidResponse(provider.displayName)
            }

            conversationHistory.append(["role": "assistant", "content": responseText])
            toolCallStatus = .idle
            return responseText
        }

        // Exhausted iterations
        toolCallStatus = .idle
        throw LLMError.invalidResponse("\(provider.displayName) (tool call loop exceeded)")
    }

    // MARK: - Google Gemini

    private func sendGemini(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?) async throws -> String {
        let apiKey = config.apiKey
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey("Gemini API key not configured")
        }

        let model = config.model
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw LLMError.invalidConfiguration("Invalid Gemini URL")
        }

        // Add user message to history
        if let imageData = imageData {
            let base64String = imageData.base64EncodedString()
            let parts: [[String: Any]] = [
                ["text": text],
                ["inlineData": ["mimeType": "image/jpeg", "data": base64String]]
            ]
            conversationHistory.append(["role": "user", "parts": parts])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()

        for iteration in 0..<maxToolCallIterations {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Gemini format: system instruction + contents array
            var contents: [[String: Any]] = []
            for msg in conversationHistory {
                let role = msg["role"] as? String ?? "user"
                if role == "user" || role == "model" {
                    let geminiRole = role == "assistant" ? "model" : role
                    if let textContent = msg["content"] as? String {
                        contents.append([
                            "role": geminiRole,
                            "parts": [["text": textContent]]
                        ])
                    } else if let parts = msg["parts"] as? [[String: Any]] {
                        contents.append([
                            "role": geminiRole,
                            "parts": parts
                        ])
                    }
                } else if role == "assistant" {
                    if let textContent = msg["content"] as? String {
                        contents.append([
                            "role": "model",
                            "parts": [["text": textContent]]
                        ])
                    } else if let parts = msg["parts"] as? [[String: Any]] {
                        contents.append([
                            "role": "model",
                            "parts": parts
                        ])
                    }
                } else if role == "function" {
                    // Function response
                    if let parts = msg["parts"] as? [[String: Any]] {
                        contents.append([
                            "role": "user",
                            "parts": parts
                        ])
                    }
                }
            }

            var body: [String: Any] = [
                "system_instruction": [
                    "parts": [["text": systemPrompt]]
                ],
                "contents": contents,
                "generationConfig": [
                    "maxOutputTokens": includeTools ? 1024 : Config.maxTokens
                ]
            ]

            if includeTools {
                body["tools"] = ToolDeclarations.geminiRESTTools()
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = errorJson["error"] as? [String: Any],
                   let errorMsg = errorObj["message"] as? String {
                    print("❌ Gemini API error \(statusCode): \(errorMsg)")
                    throw LLMError.apiError(provider: "Gemini", statusCode: statusCode, message: errorMsg)
                }
                throw LLMError.apiError(provider: "Gemini", statusCode: statusCode, message: nil)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw LLMError.invalidResponse("Gemini")
            }

            // Check for function calls in parts
            let functionCallParts = parts.filter { $0["functionCall"] != nil }

            if !functionCallParts.isEmpty, includeTools, let bridge = openClawBridge {
                // Add model response with function call to history
                conversationHistory.append([
                    "role": "assistant",
                    "parts": parts
                ])

                var functionResponseParts: [[String: Any]] = []

                for part in functionCallParts {
                    guard let funcCall = part["functionCall"] as? [String: Any],
                          let name = funcCall["name"] as? String,
                          let args = funcCall["args"] as? [String: Any] else { continue }

                    let taskDesc = args["task"] as? String ?? String(describing: args)

                    print("🔧 [Gemini] Tool call: \(name)(\(taskDesc.prefix(100))...)")
                    toolCallStatus = .executing(name)

                    let result = await bridge.delegateTask(task: taskDesc, toolName: name)
                    toolCallStatus = result.isSuccess ? .completed(name) : .failed(name, "Failed")

                    let resultContent: [String: Any]
                    switch result {
                    case .success(let text): resultContent = ["result": text]
                    case .failure(let error): resultContent = ["error": error]
                    }

                    functionResponseParts.append([
                        "functionResponse": [
                            "name": name,
                            "response": resultContent
                        ]
                    ])
                }

                // Add function responses as user role
                conversationHistory.append([
                    "role": "function",
                    "parts": functionResponseParts
                ])

                print("🔄 [Gemini] Continuing after tool call (iteration \(iteration + 1))")
                continue // Loop back to get final response
            }

            // No function calls — extract text response
            let responseText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")

            guard !responseText.isEmpty else {
                throw LLMError.invalidResponse("Gemini")
            }

            conversationHistory.append(["role": "assistant", "content": responseText])
            toolCallStatus = .idle
            return responseText
        }

        // Exhausted iterations
        toolCallStatus = .idle
        throw LLMError.invalidResponse("Gemini (tool call loop exceeded)")
    }

    // MARK: - Helpers

    private func trimHistory() {
        if conversationHistory.count > maxHistoryTurns * 2 {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
        }
    }
}

// MARK: - ToolResult Helper

extension ToolResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - LLM Errors

enum LLMError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse(String)
    case invalidConfiguration(String)
    case apiError(provider: String, statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): return msg
        case .invalidResponse(let provider): return "Invalid response from \(provider)"
        case .invalidConfiguration(let msg): return msg
        case .apiError(let provider, let code, let msg):
            if let msg { return "\(provider) error \(code): \(msg)" }
            return "\(provider) error: \(code)"
        }
    }
}
