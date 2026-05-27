import Foundation
import AppKit
import CryptoKit

enum GoogleAuthError: LocalizedError {
    case userCancelled
    case missingCode
    case tokenExchangeFailed(String)
    case stateMismatch
    /// Google refused the grant in a way that can't be retried silently — the refresh
    /// token is revoked/expired, or Google's reauth policy kicked in (e.g. `invalid_rapt`
    /// after ~24h on a Workspace account). The only recovery is a fresh interactive sign-in.
    case needsReauth(reason: String)

    var errorDescription: String? {
        switch self {
        case .userCancelled: return "Sign-in was cancelled."
        case .missingCode: return "Google did not return an authorization code."
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .stateMismatch: return "OAuth state mismatch (possible CSRF)."
        case .needsReauth(let reason): return "Session expired — please sign in again. (\(reason))"
        }
    }
}

enum GoogleAuth {
    /// Runs the full OAuth 2.0 + PKCE flow against Google using a loopback redirect.
    static func run(clientID: String, clientSecret: String, scopes: [String]) async throws -> OAuthTokens {
        let server = try LoopbackServer()
        let redirectURI = "http://127.0.0.1:\(server.port)/"

        let verifier = pkceVerifier()
        let challenge = pkceChallenge(from: verifier)
        let state = randomURLString(byteCount: 16)

        var comps = URLComponents(url: Config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = comps.url else {
            throw GoogleAuthError.tokenExchangeFailed("Could not build authorization URL")
        }

        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let params = try await server.awaitRedirect()
        if let err = params["error"], !err.isEmpty {
            throw GoogleAuthError.tokenExchangeFailed(err)
        }
        guard params["state"] == state else { throw GoogleAuthError.stateMismatch }
        guard let code = params["code"], !code.isEmpty else { throw GoogleAuthError.missingCode }

        return try await exchangeCode(
            code: code,
            verifier: verifier,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI
        )
    }

    static func refresh(refreshToken: String, clientID: String, clientSecret: String) async throws -> OAuthTokens {
        var form: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        return try await postToken(form: form, fallbackRefresh: refreshToken)
    }

    // MARK: - Internal

    private static func exchangeCode(code: String, verifier: String, clientID: String, clientSecret: String, redirectURI: String) async throws -> OAuthTokens {
        var form: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        return try await postToken(form: form, fallbackRefresh: nil)
    }

    private static func postToken(form: [String: String], fallbackRefresh: String?) async throws -> OAuthTokens {
        var req = URLRequest(url: Config.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError.tokenExchangeFailed("No HTTP response")
        }
        if http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            // Google returns `{"error":"invalid_grant", ...}` for refresh tokens that can no
            // longer be exchanged silently: revoked, expired (7+ days idle), or — most often
            // for us — `invalid_rapt`, which means Google's reauth policy now requires an
            // interactive sign-in. None of these recover by retrying the refresh.
            if let parsed = parseOAuthError(body), parsed.needsInteractiveReauth {
                throw GoogleAuthError.needsReauth(reason: parsed.userFacingReason)
            }
            throw GoogleAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(body)")
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int?
            let refresh_token: String?
            let id_token: String?
            let scope: String?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = Date().addingTimeInterval(TimeInterval(decoded.expires_in ?? 3600))
        return OAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? fallbackRefresh,
            idToken: decoded.id_token,
            expiresAt: expiry,
            scope: decoded.scope
        )
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private static func pkceVerifier() -> String {
        randomURLString(byteCount: 32)
    }

    private static func pkceChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString
    }

    private static func randomURLString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString
    }

    private struct OAuthErrorBody {
        let error: String
        let description: String?
        let subtype: String?

        /// `invalid_grant` covers every refresh-token failure mode we care about
        /// (revoked, expired, `invalid_rapt`). `invalid_client` is unrecoverable too
        /// but the user clicking sign-in again won't fix it either — still, dropping
        /// them on LoginView is friendlier than leaving them stuck in MainView.
        var needsInteractiveReauth: Bool {
            error == "invalid_grant" || error == "invalid_client"
        }

        /// Short, user-readable reason for the LoginView banner. Prefers the
        /// subtype (e.g. `invalid_rapt`) since it's the most specific signal,
        /// then the description, then the raw code.
        var userFacingReason: String {
            if let subtype, !subtype.isEmpty { return subtype }
            if let description, !description.isEmpty { return description }
            return error
        }
    }

    private static func parseOAuthError(_ body: String) -> OAuthErrorBody? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["error"] as? String, !code.isEmpty else {
            return nil
        }
        return OAuthErrorBody(
            error: code,
            description: obj["error_description"] as? String,
            subtype: obj["error_subtype"] as? String
        )
    }
}
