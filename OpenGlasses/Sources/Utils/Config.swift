import Foundation

/// A saved LLM model configuration
struct ModelConfig: Codable, Identifiable, Equatable {
    var id: String  // UUID string
    var name: String  // User-facing label, e.g. "Claude Sonnet" or "GPT-4o"
    var provider: String  // LLMProvider rawValue
    var apiKey: String
    var model: String
    var baseURL: String

    /// Convenience to get the LLMProvider enum
    var llmProvider: LLMProvider {
        LLMProvider(rawValue: provider) ?? .custom
    }

    /// Create a new config with defaults for a provider
    static func defaultConfig(for provider: LLMProvider) -> ModelConfig {
        ModelConfig(
            id: UUID().uuidString,
            name: provider.displayName,
            provider: provider.rawValue,
            apiKey: "",
            model: provider.defaultModel,
            baseURL: provider.defaultBaseURL
        )
    }
}

/// App configuration and API keys
struct Config {
    /// Anthropic API key for Claude
    static var anthropicAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "anthropicAPIKey"), !key.isEmpty {
            return key
        }
        // No API key configured - set one via Settings
        return ""
    }

    static func setAnthropicAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "anthropicAPIKey")
    }

    // MARK: - Wake Word

    /// The primary wake word phrase (user-configurable)
    static var wakePhrase: String {
        if let phrase = UserDefaults.standard.string(forKey: "wakePhrase"), !phrase.isEmpty {
            return phrase.lowercased()
        }
        return "hey claude"
    }

    static func setWakePhrase(_ phrase: String) {
        UserDefaults.standard.set(phrase.lowercased(), forKey: "wakePhrase")
    }

    /// Alternative spellings / misrecognitions of the wake phrase
    static var alternativeWakePhrases: [String] {
        if let alts = UserDefaults.standard.stringArray(forKey: "alternativeWakePhrases"), !alts.isEmpty {
            return alts.map { $0.lowercased() }
        }
        return Self.defaultAlternativesForPhrase(wakePhrase)
    }

    static func setAlternativeWakePhrases(_ phrases: [String]) {
        UserDefaults.standard.set(phrases.map { $0.lowercased() }, forKey: "alternativeWakePhrases")
    }

    /// Default alternative spellings for common wake phrases
    static func defaultAlternativesForPhrase(_ phrase: String) -> [String] {
        switch phrase.lowercased() {
        case "hey claude":
            return ["hey cloud", "hey claud", "hey clod", "hey clawed", "hey claudia"]
        case "hey jarvis":
            return ["hey jarvas", "hey jarvus", "hey service"]
        case "hey computer":
            return ["hey compuder", "a computer"]
        case "hey assistant":
            return ["hey assistance", "a assistant"]
        case "hey rayban":
            return ["hey ray ban", "hey ray-ban", "hey raven", "hey rayben", "hey ray band"]
        default:
            return []
        }
    }

    // MARK: - LLM Provider (legacy — kept for migration)

    /// Selected LLM provider
    static var llmProvider: LLMProvider {
        if let raw = UserDefaults.standard.string(forKey: "llmProvider"),
           let provider = LLMProvider(rawValue: raw) {
            return provider
        }
        return .anthropic
    }

    static func setLLMProvider(_ provider: LLMProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: "llmProvider")
    }

    /// Claude model to use
    static let claudeModel = "claude-sonnet-4-20250514"

    /// Max tokens for LLM response
    static let maxTokens = 500

    // MARK: - OpenAI-compatible

    /// OpenAI-compatible API key
    static var openAIAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "openAIAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setOpenAIAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "openAIAPIKey")
    }

    /// OpenAI-compatible base URL (supports OpenAI, Groq, Together, Ollama, etc.)
    static var openAIBaseURL: String {
        if let url = UserDefaults.standard.string(forKey: "openAIBaseURL"), !url.isEmpty {
            return url
        }
        return "https://api.openai.com/v1/chat/completions"
    }

    static func setOpenAIBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "openAIBaseURL")
    }

    /// OpenAI-compatible model name
    static var openAIModel: String {
        if let model = UserDefaults.standard.string(forKey: "openAIModel"), !model.isEmpty {
            return model
        }
        return "gpt-4o"
    }

    static func setOpenAIModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: "openAIModel")
    }

    // MARK: - Multi-Model Configurations

    private static let modelsKey = "savedModelConfigs"
    private static let activeModelKey = "activeModelId"

    /// All saved model configurations
    static var savedModels: [ModelConfig] {
        guard let data = UserDefaults.standard.data(forKey: modelsKey),
              let models = try? JSONDecoder().decode([ModelConfig].self, from: data),
              !models.isEmpty else {
            // Migrate from legacy single-provider config
            return migrateFromLegacy()
        }
        return models
    }

    static func setSavedModels(_ models: [ModelConfig]) {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: modelsKey)
        }
    }

    /// The ID of the currently active model
    static var activeModelId: String {
        if let id = UserDefaults.standard.string(forKey: activeModelKey), !id.isEmpty {
            // Make sure it still exists
            if savedModels.contains(where: { $0.id == id }) {
                return id
            }
        }
        // Default to first saved model
        return savedModels.first?.id ?? ""
    }

    static func setActiveModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeModelKey)
    }

    /// The currently active model configuration
    static var activeModel: ModelConfig? {
        let id = activeModelId
        return savedModels.first(where: { $0.id == id }) ?? savedModels.first
    }

    /// Migrate from old single-provider config to multi-model array
    private static func migrateFromLegacy() -> [ModelConfig] {
        var models: [ModelConfig] = []

        // Migrate Anthropic config if key exists and is valid
        let anthropicKey = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !anthropicKey.isEmpty {
            let config = ModelConfig(
                id: UUID().uuidString,
                name: "Claude Sonnet",
                provider: LLMProvider.anthropic.rawValue,
                apiKey: anthropicKey,
                model: claudeModel,
                baseURL: LLMProvider.anthropic.defaultBaseURL
            )
            models.append(config)
        }

        // Migrate OpenAI/Groq/Gemini/Custom config if key exists and is valid
        let otherKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !otherKey.isEmpty {
            let provider = llmProvider
            if provider != .anthropic {
                let config = ModelConfig(
                    id: UUID().uuidString,
                    name: provider.displayName,
                    provider: provider.rawValue,
                    apiKey: otherKey,
                    model: openAIModel,
                    baseURL: openAIBaseURL
                )
                models.append(config)
            }
        }

        // If nothing was migrated, create a blank Anthropic default
        if models.isEmpty {
            models.append(ModelConfig.defaultConfig(for: .anthropic))
        }

        // Defensive check - should never happen, but prevent crash
        guard let firstModel = models.first else {
            print("⚠️ Migration failed - no models created")
            // Create emergency default
            let emergency = ModelConfig.defaultConfig(for: .anthropic)
            models = [emergency]
            setSavedModels(models)
            setActiveModelId(emergency.id)
            return models
        }

        // Save the migration
        setSavedModels(models)
        setActiveModelId(firstModel.id)

        return models
    }

    // MARK: - Custom System Prompt

    static let defaultSystemPrompt = """
    You are a voice assistant running on Ray-Ban Meta smart glasses. Your responses will be spoken aloud via text-to-speech.

    RESPONSE STYLE:
    - Keep responses CONCISE but COMPLETE — typically 2-4 sentences, longer for complex topics.
    - Be conversational and natural, like talking to a knowledgeable friend.
    - Never use markdown, bullet points, numbered lists, or special formatting.
    - If you're uncertain, use natural hedges like "probably", "likely", or "roughly" rather than stating guesses as facts.
    - If you genuinely can't answer (e.g., real-time data, personal info you don't have), say so briefly and suggest what the user could do instead.

    CONTEXT:
    - The user is wearing smart glasses and talking to you hands-free while going about their day.
    - Speech recognition may mishear words — interpret the user's intent generously.
    - You have conversational memory within this session, so you can reference previous exchanges.
    - For very complex questions, offer to break the topic into parts: "That's a big topic. Would you like me to start with X?"

    KNOWLEDGE:
    - Answer confidently from your training knowledge for factual questions.
    - Give direct recommendations when asked for opinions.
    - If the user's location is provided, use it for locally relevant answers (nearby places, directions, local knowledge). Only mention the location if it's directly relevant to the question.

    BREVITY GUIDELINES:
    - Simple facts: 1-2 sentences ("Paris is the capital of France, located in northern France along the Seine River.")
    - Explanations: 3-4 sentences (e.g., "how does X work?")
    - Complex topics: 4-6 sentences, offer to continue (e.g., "Want me to explain more about Y?")
    - Directions/instructions: As many steps as needed, but keep each step concise.
    """

    static var systemPrompt: String {
        if let prompt = UserDefaults.standard.string(forKey: "customSystemPrompt"), !prompt.isEmpty {
            return prompt
        }
        return defaultSystemPrompt
    }

    static func setSystemPrompt(_ prompt: String) {
        UserDefaults.standard.set(prompt, forKey: "customSystemPrompt")
    }

    static func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: "customSystemPrompt")
    }

    // MARK: - OAuth Token Management (Claude Max/Pro)

    /// Set up OAuth tokens for Claude Max/Pro subscription
    static func setupOAuthTokens(accessToken: String, refreshToken: String, expiresAt: Double) {
        Task {
            await OAuthTokenManager.shared.saveTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt
            )
        }
    }

    /// Whether OAuth is configured
    static var isOAuthConfigured: Bool {
        let rt = UserDefaults.standard.string(forKey: "oauthRefreshToken") ?? ""
        return !rt.isEmpty
    }

    // MARK: - ElevenLabs TTS

    /// ElevenLabs API key for natural TTS voices
    static var elevenLabsAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "elevenLabsAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setElevenLabsAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "elevenLabsAPIKey")
    }

    /// ElevenLabs voice ID - default is "Rachel" (warm, conversational female voice)
    /// Other good options:
    ///   "21m00Tcm4TlvDq8ikWAM" = Rachel (default)
    ///   "EXAVITQu4vr4xnSDxMaL" = Bella (young, conversational)
    ///   "pNInz6obpgDQGcFmaJgB" = Adam (deep male)
    ///   "ErXwobaYiN019PkySvjV" = Antoni (friendly male)
    ///   "onwK4e9ZLuTAKqWW03F9" = Daniel (British male)
    static var elevenLabsVoiceId: String {
        if let voiceId = UserDefaults.standard.string(forKey: "elevenLabsVoiceId"), !voiceId.isEmpty {
            return voiceId
        }
        return "21m00Tcm4TlvDq8ikWAM"  // Rachel
    }

    static func setElevenLabsVoiceId(_ voiceId: String) {
        UserDefaults.standard.set(voiceId, forKey: "elevenLabsVoiceId")
    }

    // MARK: - App Mode

    static var appMode: AppMode {
        if let raw = UserDefaults.standard.string(forKey: "appMode"),
           let mode = AppMode(rawValue: raw) {
            return mode
        }
        return .direct
    }

    static func setAppMode(_ mode: AppMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "appMode")
    }

    // MARK: - OpenClaw Configuration

    static var openClawEnabled: Bool {
        UserDefaults.standard.bool(forKey: "openClawEnabled")
    }

    static func setOpenClawEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "openClawEnabled")
    }

    static var openClawConnectionMode: OpenClawConnectionMode {
        if let raw = UserDefaults.standard.string(forKey: "openClawConnectionMode"),
           let mode = OpenClawConnectionMode(rawValue: raw) {
            return mode
        }
        return .auto
    }

    static func setOpenClawConnectionMode(_ mode: OpenClawConnectionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "openClawConnectionMode")
    }

    static var openClawLanHost: String {
        if let host = UserDefaults.standard.string(forKey: "openClawLanHost"), !host.isEmpty {
            return host
        }
        return "http://macbook.local"
    }

    static func setOpenClawLanHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "openClawLanHost")
    }

    static var openClawPort: Int {
        let port = UserDefaults.standard.integer(forKey: "openClawPort")
        return port != 0 ? port : 18789
    }

    static func setOpenClawPort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: "openClawPort")
    }

    static var openClawTunnelHost: String {
        if let host = UserDefaults.standard.string(forKey: "openClawTunnelHost"), !host.isEmpty {
            return host
        }
        return ""
    }

    static func setOpenClawTunnelHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "openClawTunnelHost")
    }

    static var openClawGatewayToken: String {
        if let token = UserDefaults.standard.string(forKey: "openClawGatewayToken"), !token.isEmpty {
            return token
        }
        return ""
    }

    static func setOpenClawGatewayToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "openClawGatewayToken")
    }

    static var isOpenClawConfigured: Bool {
        openClawEnabled && !openClawGatewayToken.isEmpty
    }

    // MARK: - Gemini Live Configuration

    static var geminiLiveModelConfig: ModelConfig? {
        if let active = activeModel, active.llmProvider == .gemini {
            return active
        }
        return savedModels.first(where: { $0.provider == LLMProvider.gemini.rawValue })
    }

    static var geminiLiveAPIKey: String {
        return geminiLiveModelConfig?.apiKey ?? ""
    }

    static var geminiLiveModel: String {
        if let geminiConfig = geminiLiveModelConfig {
            let m = geminiConfig.model
            if m.hasPrefix("models/") { return m }
            return "models/\(m)"
        }
        return "models/gemini-2.0-flash-exp"
    }

    static let geminiLiveWebSocketBaseURL =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    static var geminiLiveWebSocketURL: URL? {
        let key = geminiLiveAPIKey
        guard !key.isEmpty else { return nil }
        return URL(string: "\(geminiLiveWebSocketBaseURL)?key=\(key)")
    }

    static let geminiLiveInputSampleRate: Double = 16000
    static let geminiLiveOutputSampleRate: Double = 24000
    static let geminiLiveAudioChannels: UInt32 = 1
    static let geminiLiveAudioBitsPerSample: UInt32 = 16
    static let geminiLiveVideoFrameInterval: TimeInterval = 1.0
    static let geminiLiveVideoJPEGQuality: CGFloat = 0.5

    static var isGeminiLiveConfigured: Bool {
        !geminiLiveAPIKey.isEmpty
    }
}

// MARK: - App Mode Enum

enum AppMode: String, CaseIterable {
    case direct = "direct"
    case geminiLive = "geminiLive"

    var displayName: String {
        switch self {
        case .direct: return "Direct Mode"
        case .geminiLive: return "Gemini Live"
        }
    }

    var description: String {
        switch self {
        case .direct: return "Wake word, any LLM provider, text-to-speech"
        case .geminiLive: return "Real-time audio/video streaming via Gemini"
        }
    }
}
