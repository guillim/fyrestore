import Foundation

/// One step in a Firestore traversal: either a collection id or a document id.
/// A valid path alternates collection → document → collection → … and ends in a collection.
enum PathSegment: Equatable, Hashable {
    case collection(String)
    case document(String)

    var label: String {
        switch self {
        case .collection(let id): return id
        case .document(let id): return id
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }
}

/// Full path to a collection (always ends with `.collection`).
struct FirestorePath: Equatable, Hashable {
    let projectId: String
    let databaseId: String
    let segments: [PathSegment]

    init(projectId: String, databaseId: String, segments: [PathSegment]) {
        self.projectId = projectId
        self.databaseId = databaseId
        self.segments = segments
    }

    /// Convenience: a top-level (root) collection.
    static func root(projectId: String, databaseId: String, collection: String) -> FirestorePath {
        FirestorePath(projectId: projectId, databaseId: databaseId, segments: [.collection(collection)])
    }

    /// Trailing collection id (the one we list documents in).
    var collectionId: String {
        guard case .collection(let id) = segments.last else { return "" }
        return id
    }

    /// Parent resource name (the URL piece that precedes the trailing collection):
    ///   projects/{p}/databases/{d}/documents[/colA/docA/colB/docB...]
    var parentResourceName: String {
        var s = "projects/\(projectId)/databases/\(databaseId)/documents"
        for seg in segments.dropLast() {
            s += "/\(seg.label)"
        }
        return s
    }

    /// Append a document id (you've selected a document), then a sub-collection id under it.
    func appending(document: String, subcollection: String) -> FirestorePath {
        var s = segments
        s.append(.document(document))
        s.append(.collection(subcollection))
        return FirestorePath(projectId: projectId, databaseId: databaseId, segments: s)
    }

    /// Truncate to the first `count` segments.
    func prefix(_ count: Int) -> FirestorePath {
        FirestorePath(projectId: projectId, databaseId: databaseId, segments: Array(segments.prefix(count)))
    }

    var isRootCollection: Bool {
        segments.count == 1
    }
}
