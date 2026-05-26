import Foundation
import AppKit
import SwiftUI

enum Clipboard {
    static func setString(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

enum FirebaseConsole {
    /// Build the Firebase Console URL for a Firestore document.
    /// Format: https://console.firebase.google.com/project/{p}/firestore/databases/{d}/data/~2F{path}
    /// where slashes in the path are encoded as `~2F` and `(default)` maps to `-default-`.
    static func url(forDocumentName name: String, project: String, database: String) -> URL? {
        let parts = name.split(separator: "/").map(String.init)
        guard let docsIdx = parts.firstIndex(of: "documents"), docsIdx + 1 < parts.count else { return nil }
        let path = parts[(docsIdx + 1)...].joined(separator: "~2F")
        let dbForURL = database == "(default)" ? "-default-" : database
        let s = "https://console.firebase.google.com/project/\(project)/firestore/databases/\(dbForURL)/data/~2F\(path)"
        return URL(string: s)
    }
}

/// SwiftUI environment slot for "navigate to a Firestore document reference value".
/// FieldRow uses this to make `.reference` values clickable without holding a model reference.
private struct ReferenceNavigatorKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var referenceNavigator: ((String) -> Void)? {
        get { self[ReferenceNavigatorKey.self] }
        set { self[ReferenceNavigatorKey.self] = newValue }
    }
}
