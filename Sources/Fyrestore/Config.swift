import Foundation

/// OAuth configuration.
///
/// Fyrestore ships with a single embedded Google OAuth Desktop client. End users do **not**
/// register their own — they just sign in with their Google account and view their own Firestore
/// data (any project their Google account has IAM access to).
///
/// If you're forking this repo: register a Desktop OAuth client once in Google Cloud Console
/// and paste the values below. See README → "For maintainers / forking the repo".
///
/// The env-var overrides exist for local development only (rotating clients, dev vs prod
/// clients, CI). End users never set these.
enum Config {
    /// Desktop OAuth Client ID. Lives in the gitignored `Secrets.swift` so it never enters
    /// git history (per RFC 8252 it's not actually confidential, but secret scanners flag it).
    /// Run `./scripts/setup-secrets.sh` after cloning to generate Secrets.swift locally.
    private static var embeddedClientID: String { Secrets.clientID }

    /// Client "secret" Google issues alongside the Desktop client. Per RFC 8252, this is NOT
    /// a real secret for native apps — it's a public string the token endpoint requires.
    /// Also stored in Secrets.swift, gitignored.
    private static var embeddedClientSecret: String { Secrets.clientSecret }

    static var clientID: String {
        if let env = ProcessInfo.processInfo.environment["FYRESTORE_CLIENT_ID"], !env.isEmpty {
            return env
        }
        return embeddedClientID
    }

    static var clientSecret: String {
        if let env = ProcessInfo.processInfo.environment["FYRESTORE_CLIENT_SECRET"], !env.isEmpty {
            return env
        }
        return embeddedClientSecret
    }

    static let scopes: [String] = [
        "https://www.googleapis.com/auth/cloud-platform.read-only",
        "https://www.googleapis.com/auth/datastore",
        "openid",
        "email"
    ]

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
}
