import Foundation

struct OAuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var scope: String?

    var idTokenEmail: String? {
        guard let idToken = idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        guard let data = Data(base64URLEncoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }
}

extension Data {
    init?(base64URLEncoded: String) {
        var s = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = 4 - (s.count % 4)
        if pad < 4 { s.append(String(repeating: "=", count: pad)) }
        self.init(base64Encoded: s)
    }
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
