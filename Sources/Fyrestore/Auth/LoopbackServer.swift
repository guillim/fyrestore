import Foundation
import Darwin

/// Minimal one-shot HTTP listener used to receive the OAuth redirect.
/// Implemented with raw POSIX sockets — Network.framework's NWListener has been
/// flaky for this exact scenario (loopback / `127.0.0.1` / OS-assigned port) on macOS.
/// BSD sockets are rock-solid and ~50 lines.
final class LoopbackServer: @unchecked Sendable {
    enum LoopbackError: LocalizedError {
        case socketFailed(String)
        case timeout
        case malformedRequest

        var errorDescription: String? {
            switch self {
            case .socketFailed(let reason): return "Loopback listener failed: \(reason)"
            case .timeout: return "Loopback listener timed out waiting for Google's redirect."
            case .malformedRequest: return "Loopback listener received a malformed request."
            }
        }
    }

    private let listenFD: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LoopbackError.socketFailed("socket(): \(Self.errnoString())")
        }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // let the kernel pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw LoopbackError.socketFailed("bind(): \(Self.errnoString())")
        }

        guard Darwin.listen(fd, 1) == 0 else {
            close(fd)
            throw LoopbackError.socketFailed("listen(): \(Self.errnoString())")
        }

        // Read back the assigned port.
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsockResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(fd, saPtr, &len)
            }
        }
        guard getsockResult == 0 else {
            close(fd)
            throw LoopbackError.socketFailed("getsockname(): \(Self.errnoString())")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit {
        close(listenFD)
    }

    /// Waits for the first redirect request and returns its query items.
    func awaitRedirect(timeout: TimeInterval = 300) async throws -> [String: String] {
        let fd = self.listenFD
        let task = Task.detached(priority: .userInitiated) { () throws -> [String: String] in
            // Block on accept until a browser hits the redirect URL.
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(fd, &clientAddr, &clientLen)
            guard clientFD >= 0 else {
                throw LoopbackError.socketFailed("accept(): \(Self.errnoString())")
            }
            defer { close(clientFD) }

            // Read the HTTP request. A redirect with query params is tiny — 4 KB is plenty.
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(clientFD, &buf, buf.count)
            guard n > 0, let req = String(bytes: buf[0..<n], encoding: .utf8) else {
                Self.writeResponse(clientFD, html: Self.errorHTML)
                throw LoopbackError.malformedRequest
            }

            guard let params = Self.parseRequest(req) else {
                Self.writeResponse(clientFD, html: Self.errorHTML)
                throw LoopbackError.malformedRequest
            }

            Self.writeResponse(clientFD, html: Self.successHTML)
            return params
        }

        // Timeout safety net: if the user closes the browser tab, we don't want to hang forever.
        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LoopbackError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers

    private static func parseRequest(_ raw: String) -> [String: String]? {
        // First line: "GET /?code=...&state=... HTTP/1.1"
        guard let firstLine = raw.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let pathAndQuery = String(parts[1])
        guard let q = pathAndQuery.split(separator: "?").dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, let k = kv[0].removingPercentEncoding, let v = kv[1].removingPercentEncoding {
                out[k] = v
            } else if kv.count == 1, let k = kv[0].removingPercentEncoding {
                out[k] = ""
            }
        }
        return out
    }

    private static func writeResponse(_ fd: Int32, html: String) {
        let bytes = Array(html.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r

        """
        let headerBytes = Array(header.utf8)
        _ = headerBytes.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
        _ = bytes.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
    }

    private static func errnoString() -> String {
        let err = errno
        return "errno \(err) (\(String(cString: strerror(err))))"
    }

    private static let successHTML = """
    <!doctype html><html><head><title>Fyrestore</title>
    <style>body{font-family:-apple-system,system-ui,sans-serif;background:#fafaf7;color:#37352f;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    .card{background:#fff;border:1px solid #ebebe9;border-radius:8px;padding:32px 40px;text-align:center;
    box-shadow:0 1px 2px rgba(0,0,0,.04)} h1{font-size:18px;margin:0 0 8px}
    p{margin:0;color:#787673;font-size:14px}</style></head>
    <body><div class="card"><h1>Signed in</h1><p>You can close this tab and return to Fyrestore.</p></div></body></html>
    """

    private static let errorHTML = """
    <!doctype html><html><body><h1>Sign-in failed</h1><p>Please return to Fyrestore and try again.</p></body></html>
    """
}
