import Foundation

struct GCPProject: Identifiable, Hashable {
    let projectId: String
    let name: String
    var id: String { projectId }
}

struct FirestoreDatabase: Identifiable, Hashable {
    /// Database ID — usually "(default)".
    let databaseId: String
    /// Full name: projects/{p}/databases/{d}
    let name: String
    var id: String { name }
}

struct FirestoreDocument: Identifiable, Hashable {
    /// Full resource name: projects/.../documents/collection/docId[/...]
    let name: String
    let createTime: String?
    let updateTime: String?
    let fields: [FirestoreField]

    var id: String { name }
    var shortId: String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// Pick up to `limit` fields that are likely to be useful to show in a one-line
    /// preview (the doc list cell). Uses heuristics: prefer common human-readable
    /// names (name, title, email, …), prefer short strings, penalize id-like fields,
    /// IDs/timestamps, and complex/empty values.
    func previewFields(limit: Int = 2) -> [FirestoreField] {
        let scored = fields.map { (field: $0, score: Self.previewScore(for: $0)) }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.field.name < rhs.field.name
            }
            .prefix(limit)
            .map { $0.field }
    }

    private static let preferredFieldNames: Set<String> = [
        "name", "title", "label", "displayname", "fullname",
        "firstname", "lastname", "email", "username",
        "description", "summary", "subject", "status", "type"
    ]

    private static func previewScore(for field: FirestoreField) -> Int {
        let lc = field.name.lowercased()
        var score = 0

        if preferredFieldNames.contains(lc) { score += 20 }

        if lc == "id" || lc == "_id" {
            score -= 15
        } else if lc.hasSuffix("id") || lc.hasSuffix("uuid") || lc.hasSuffix("ref") {
            score -= 8
        }

        switch field.value {
        case .string(let s):
            score += 5
            if s.isEmpty { score -= 5 }
            else if s.count <= 60 { score += 3 }
            else if s.count > 200 { score -= 4 }
        case .integer, .double:
            score += 3
        case .boolean:
            score += 2
        case .timestamp:
            score -= 2
        case .null:
            score -= 10
        case .array, .map:
            score -= 5
        case .bytes, .reference:
            score -= 3
        case .geoPoint:
            score += 1
        }
        return score
    }

    /// Evaluate a client-side filter against this document. Currently used for the
    /// `contains` (case-insensitive substring) operator. Returns false for ops that
    /// aren't client-side — those go through Firestore's `runQuery`.
    func matches(_ filter: QueryFilter) -> Bool {
        guard let entry = fields.first(where: { $0.name == filter.field }) else { return false }
        switch filter.op {
        case .contains:
            let needle = filter.value.searchableString.lowercased()
            return entry.value.searchableString.lowercased().contains(needle)
        default:
            return false
        }
    }

    /// Pretty-printed JSON of the document's decoded fields.
    /// Returns an empty `{}` string if encoding somehow fails (shouldn't happen for
    /// well-formed Firestore data, but we'd rather paste empty than crash).
    func prettyJSON() -> String {
        var obj: [String: Any] = [:]
        for f in fields { obj[f.name] = f.value.jsonValue }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: opts),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    static func == (lhs: FirestoreDocument, rhs: FirestoreDocument) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

enum FirestoreError: LocalizedError {
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .decode(let msg): return "Decoding error: \(msg)"
        }
    }
}

/// One page of documents, plus a token to fetch the next page if any.
struct DocumentPage {
    let documents: [FirestoreDocument]
    let nextPageToken: String?
}

/// Talks to Google Cloud Resource Manager + Firestore REST APIs.
struct FirestoreClient {
    let session: Session

    private func authorizedRequest(url: URL, method: String = "GET", body: Data? = nil) async throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let token = try await session.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FirestoreError.http(0, "no response")
        }
        if http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FirestoreError.http(http.statusCode, body)
        }
        return data
    }

    /// Builds an authorized request, sends it, and retries once if Google returns 401
    /// — that happens when the access token we cached as "still valid" was actually
    /// revoked or invalidated server-side (token rotation, scope change, clock skew).
    /// On 401 we mark the cached token stale and rebuild the request, which forces
    /// `Session.accessToken()` to go through `refresh`. If the refresh itself raises
    /// `needsReauth`, `Session` will have already cleared the session and surfaced a
    /// message on the LoginView; the error bubbles up so the in-flight UI call aborts.
    private func performAuthorized(url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        let req = try await authorizedRequest(url: url, method: method, body: body)
        do {
            return try await send(req)
        } catch FirestoreError.http(let code, _) where code == 401 {
            await session.invalidateAccessToken()
            let retryReq = try await authorizedRequest(url: url, method: method, body: body)
            return try await send(retryReq)
        }
    }

    // MARK: - Projects

    func listProjects() async throws -> [GCPProject] {
        var url = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
        var all: [GCPProject] = []
        while true {
            let data = try await performAuthorized(url: url)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let projects = (json["projects"] as? [[String: Any]]) ?? []
            for p in projects {
                guard let id = p["projectId"] as? String else { continue }
                let lifecycle = (p["lifecycleState"] as? String) ?? "ACTIVE"
                guard lifecycle == "ACTIVE" else { continue }
                all.append(GCPProject(projectId: id, name: (p["name"] as? String) ?? id))
            }
            guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
            var comps = URLComponents(url: URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "pageToken", value: next)]
            url = comps.url!
        }
        return all.sorted { $0.projectId < $1.projectId }
    }

    // MARK: - Databases

    func listDatabases(projectId: String) async throws -> [FirestoreDatabase] {
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases")!
        let data = try await performAuthorized(url: url)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let dbs = (json["databases"] as? [[String: Any]]) ?? []
        return dbs.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            let id = name.split(separator: "/").last.map(String.init) ?? "(default)"
            return FirestoreDatabase(databaseId: id, name: name)
        }
    }

    // MARK: - Collections

    /// Top-level collection IDs for the database.
    func listRootCollections(projectId: String, databaseId: String) async throws -> [String] {
        let parent = "projects/\(projectId)/databases/\(databaseId)/documents"
        return try await listCollectionIds(parent: parent)
    }

    /// Sub-collections under a specific document.
    func listDocumentSubcollections(documentResourceName: String) async throws -> [String] {
        return try await listCollectionIds(parent: documentResourceName)
    }

    private func listCollectionIds(parent: String) async throws -> [String] {
        let url = URL(string: "https://firestore.googleapis.com/v1/\(parent):listCollectionIds")!
        let body = "{}".data(using: .utf8)
        let data = try await performAuthorized(url: url, method: "POST", body: body)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let ids = (json["collectionIds"] as? [String]) ?? []
        return ids.sorted()
    }

    // MARK: - Documents (plain list, paginated)

    /// Lists one page of documents at `path`. Pass the returned `nextPageToken` back in
    /// for subsequent pages.
    func listDocuments(at path: FirestorePath, pageSize: Int = 100, pageToken: String? = nil) async throws -> DocumentPage {
        var comps = URLComponents(string: "https://firestore.googleapis.com/v1/\(path.parentResourceName)/\(path.collectionId)")!
        var items: [URLQueryItem] = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let pageToken, !pageToken.isEmpty {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        comps.queryItems = items
        let data = try await performAuthorized(url: comps.url!)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let raw = (json["documents"] as? [[String: Any]]) ?? []
        let docs = raw.compactMap { Self.decodeDocument($0) }
        let next = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DocumentPage(documents: docs, nextPageToken: next)
    }

    // MARK: - Documents (filtered via runQuery)

    /// Runs a single-field structured query at `path`. Capped at `limit` results.
    func runQuery(at path: FirestorePath, filter: QueryFilter, limit: Int = 100) async throws -> [FirestoreDocument] {
        let url = URL(string: "https://firestore.googleapis.com/v1/\(path.parentResourceName):runQuery")!
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": path.collectionId]],
                "where": [
                    "fieldFilter": [
                        "field": ["fieldPath": filter.field],
                        "op": filter.op.firestoreOpName,
                        "value": filter.value.firestoreJSON
                    ]
                ],
                "limit": limit
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await performAuthorized(url: url, method: "POST", body: bodyData)
        // runQuery returns an array of entries, some of which may be empty (e.g. cursor markers).
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var docs: [FirestoreDocument] = []
        for entry in arr {
            guard let doc = entry["document"] as? [String: Any] else { continue }
            if let decoded = Self.decodeDocument(doc) {
                docs.append(decoded)
            }
        }
        return docs
    }

    static func decodeDocument(_ obj: [String: Any]) -> FirestoreDocument? {
        guard let name = obj["name"] as? String else { return nil }
        let fields = (obj["fields"] as? [String: Any]) ?? [:]
        let decoded = FirestoreValueDecoder.decodeFields(fields)
        return FirestoreDocument(
            name: name,
            createTime: obj["createTime"] as? String,
            updateTime: obj["updateTime"] as? String,
            fields: decoded
        )
    }
}
