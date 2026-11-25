import Foundation
import SwiftUI

@MainActor
final class Session: ObservableObject {
    @Published var tokens: OAuthTokens?
    @Published var userEmail: String?
    @Published var authError: String?
    @Published var isAuthenticating = false

    private let tokenStore = KeychainTokenStore()

    /// Email of the last account that signed in. Survives a forced re-auth (but not
    /// an explicit sign-out) so the next sign-in can skip the account chooser.
    private static let lastEmailKey = "fyrestore.lastSignedInEmail"
    private var lastEmail: String? {
        get { UserDefaults.standard.string(forKey: Self.lastEmailKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastEmailKey) }
    }

    init() {
        if let saved = tokenStore.load() {
            self.tokens = saved
            self.userEmail = saved.idTokenEmail
            if let email = saved.idTokenEmail { lastEmail = email }
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
            var result = try await GoogleAuth.run(
                clientID: Config.clientID,
                clientSecret: Config.clientSecret,
                scopes: Config.scopes,
                loginHint: lastEmail
            )
            // The fast path skips the consent screen. If Google didn't hand back a
            // refresh token that way, go through full consent once so silent
            // refresh keeps working.
            if result.refreshToken == nil {
                result = try await GoogleAuth.run(
                    clientID: Config.clientID,
                    clientSecret: Config.clientSecret,
                    scopes: Config.scopes,
                    loginHint: lastEmail,
                    forceConsent: true
                )
            }
            self.tokens = result
            self.userEmail = result.idTokenEmail
            if let email = result.idTokenEmail { lastEmail = email }
            try? tokenStore.save(result)
        } catch {
            authError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        tokens = nil
        userEmail = nil
        authError = nil
        lastEmail = nil
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
            invalidateSession(reason: "Session expired. Please sign in again.")
            throw GoogleAuthError.needsReauth(reason: "no refresh token")
        }
        do {
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
        } catch let error as GoogleAuthError {
            if case .needsReauth(let reason) = error {
                invalidateSession(reason: "Your Google sign-in needs to be refreshed (\(reason)). Please sign in again.")
            }
            throw error
        }
    }

    /// Mark the cached access token as stale so the next `accessToken()` call goes
    /// through `refresh` regardless of `expiresAt`. Used by the API layer when the
    /// server returns 401 with what we believed was still a valid token (revoked
    /// server-side, scope mismatch, clock skew). The refresh token is left intact.
    func invalidateAccessToken() {
        guard var t = tokens else { return }
        t.expiresAt = Date(timeIntervalSinceNow: -1)
        tokens = t
    }

    /// Tear down the current session because the stored refresh token can no longer be
    /// exchanged. Clears in-memory + Keychain tokens and surfaces `reason` on the
    /// LoginView via `authError`. Setting `tokens = nil` causes `RootView` to flip
    /// back to `LoginView` automatically — the user lands there with one obvious
    /// next step (the "Sign in with Google" button).
    private func invalidateSession(reason: String) {
        tokens = nil
        userEmail = nil
        authError = reason
        try? tokenStore.clear()
    }
}
