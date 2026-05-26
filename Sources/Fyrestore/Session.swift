import Foundation
import SwiftUI

@MainActor
final class Session: ObservableObject {
    @Published var tokens: OAuthTokens?
    @Published var userEmail: String?
    @Published var authError: String?
    @Published var isAuthenticating = false

    private let tokenStore = KeychainTokenStore()

    init() {
        if let saved = tokenStore.load() {
            self.tokens = saved
            self.userEmail = saved.idTokenEmail
        }
    }

    var isSignedIn: Bool { tokens != nil }

    func signIn() async {
        guard !Config.clientID.isEmpty else {
            authError = "This build of Fyrestore is missing its OAuth client. If you built from source, see README → \"For maintainers\"."
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        authError = nil
        do {
            let result = try await GoogleAuth.run(
                clientID: Config.clientID,
                clientSecret: Config.clientSecret,
                scopes: Config.scopes
            )
            self.tokens = result
            self.userEmail = result.idTokenEmail
            try? tokenStore.save(result)
        } catch {
            authError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        tokens = nil
        userEmail = nil
        try? tokenStore.clear()
    }

    /// Returns a non-expired access token, refreshing if needed.
    func accessToken() async throws -> String {
        guard var tokens = tokens else {
            throw NSError(domain: "Fyrestore", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        guard let refresh = tokens.refreshToken else {
            self.tokens = nil
            throw NSError(domain: "Fyrestore", code: 401, userInfo: [NSLocalizedDescriptionKey: "Session expired, please sign in again"])
        }
        let refreshed = try await GoogleAuth.refresh(
            refreshToken: refresh,
            clientID: Config.clientID,
            clientSecret: Config.clientSecret
        )
        // Refresh response sometimes omits refresh_token; keep the existing one.
        tokens.accessToken = refreshed.accessToken
        tokens.expiresAt = refreshed.expiresAt
        if let newRefresh = refreshed.refreshToken { tokens.refreshToken = newRefresh }
        self.tokens = tokens
        try? tokenStore.save(tokens)
        return tokens.accessToken
    }
}
