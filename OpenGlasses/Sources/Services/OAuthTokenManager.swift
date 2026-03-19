import Foundation

/// Manages OAuth tokens for Claude Max/Pro subscriptions.
/// Automatically refreshes expired access tokens using the stored refresh token.
actor OAuthTokenManager {
    static let shared = OAuthTokenManager()

    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let tokenURL = "https://claude.ai/api/oauth/token"

    private var accessToken: String = ""
    private var refreshToken: String = ""
    private var expiresAt: Date = .distantPast

    private let accessTokenKey = "oauthAccessToken"
    private let refreshTokenKey = "oauthRefreshToken"
    private let expiresAtKey = "oauthExpiresAt"

    private init() {
        // Load saved tokens from UserDefaults
        let defaults = UserDefaults.standard
        self.accessToken = defaults.string(forKey: accessTokenKey) ?? ""
        self.refreshToken = defaults.string(forKey: refreshTokenKey) ?? ""
        let expiresMs = defaults.double(forKey: expiresAtKey)
        if expiresMs > 0 {
            self.expiresAt = Date(timeIntervalSince1970: expiresMs / 1000)
        }
    }

    /// Whether OAuth is configured (has a refresh token)
    var isConfigured: Bool {
        !refreshToken.isEmpty
    }

    /// Get a valid access token, refreshing if expired
    func getValidAccessToken() async throws -> String {
        // If token is still valid (with 5 min buffer), return it
        if !accessToken.isEmpty && Date() < expiresAt.addingTimeInterval(-300) {
            return accessToken
        }

        // Need to refresh
        guard !refreshToken.isEmpty else {
            throw OAuthError.noRefreshToken
        }

        return try await refreshAccessToken()
    }

    /// Save tokens (called when user configures OAuth)
    func saveTokens(accessToken: String, refreshToken: String, expiresAt: Double) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date(timeIntervalSince1970: expiresAt / 1000)

        let defaults = UserDefaults.standard
        defaults.set(accessToken, forKey: accessTokenKey)
        defaults.set(refreshToken, forKey: refreshTokenKey)
        defaults.set(expiresAt, forKey: expiresAtKey)
    }

    /// Clear all stored tokens
    func clearTokens() {
        self.accessToken = ""
        self.refreshToken = ""
        self.expiresAt = .distantPast

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: accessTokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: expiresAtKey)
    }

    /// Refresh the access token using the refresh token
    private func refreshAccessToken() async throws -> String {
        print("🔄 Refreshing OAuth access token...")

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("❌ OAuth refresh failed with status \(statusCode)")
            throw OAuthError.refreshFailed(statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw OAuthError.invalidResponse
        }

        self.accessToken = newAccessToken

        // Update expiry (default 8 hours if not provided)
        if let expiresIn = json["expires_in"] as? Double {
            self.expiresAt = Date().addingTimeInterval(expiresIn)
            let expiresMs = self.expiresAt.timeIntervalSince1970 * 1000
            UserDefaults.standard.set(expiresMs, forKey: expiresAtKey)
        } else {
            self.expiresAt = Date().addingTimeInterval(8 * 3600)
            let expiresMs = self.expiresAt.timeIntervalSince1970 * 1000
            UserDefaults.standard.set(expiresMs, forKey: expiresAtKey)
        }

        // Update refresh token if a new one was provided
        if let newRefreshToken = json["refresh_token"] as? String, !newRefreshToken.isEmpty {
            self.refreshToken = newRefreshToken
            UserDefaults.standard.set(newRefreshToken, forKey: refreshTokenKey)
        }

        UserDefaults.standard.set(newAccessToken, forKey: accessTokenKey)

        print("✅ OAuth token refreshed, expires at \(expiresAt)")
        return newAccessToken
    }
}

enum OAuthError: LocalizedError {
    case noRefreshToken
    case refreshFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noRefreshToken:
            return "No refresh token configured. Please set up OAuth tokens in Settings."
        case .refreshFailed(let code):
            return "Token refresh failed (HTTP \(code)). Please re-authenticate."
        case .invalidResponse:
            return "Invalid response from token refresh endpoint."
        }
    }
}
