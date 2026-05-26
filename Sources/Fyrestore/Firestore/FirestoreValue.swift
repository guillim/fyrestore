import Foundation

/// An ordered name/value pair inside a Firestore map or document.
struct FirestoreField: Equatable {
    let name: String
    let value: FirestoreValue
}

/// Decoded representation of a Firestore "Value" union.
/// See https://firebase.google.com/docs/firestore/reference/rest/v1/Value
indirect enum FirestoreValue: Equatable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case double(Double)
    case timestamp(String)
    case string(String)
    case bytes(String) // base64
    case reference(String)
    case geoPoint(Double, Double)
    case array([FirestoreValue])
    case map([FirestoreField])

    /// Short, single-line text for the document-list cells.
    var preview: String {
        switch self {
        case .null: return "null"
        case .boolean(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .timestamp(let s): return s
        case .string(let s): return s
        case .bytes: return "<bytes>"
        case .reference(let r): return r
        case .geoPoint(let lat, let lng): return "(\(lat), \(lng))"
        case .array(let a): return "[\(a.count)]"
        case .map(let m): return "{\(m.count)}"
        }
    }

    /// Decoded, JSON-serializable representation (i.e. plain Swift types JSONSerialization
    /// can encode). Used by the document "copy as JSON" action.
    var jsonValue: Any {
        switch self {
        case .null: return NSNull()
        case .boolean(let b): return b
        case .integer(let i): return NSNumber(value: i)
        case .double(let d): return d
        case .timestamp(let s): return s
        case .string(let s): return s
        case .bytes(let s): return s
        case .reference(let s): return s
        case .geoPoint(let lat, let lng): return ["latitude": lat, "longitude": lng]
        case .array(let arr): return arr.map { $0.jsonValue }
        case .map(let fields):
            var out: [String: Any] = [:]
            for f in fields { out[f.name] = f.value.jsonValue }
            return out
        }
    }

    /// Pretty-printed JSON of this single value. Works for primitives via the
    /// fragmentsAllowed JSON writing option.
    func prettyJSON() -> String {
        let json = self.jsonValue
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: opts),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return preview
    }

    /// For `.timestamp` values: a human-readable relative string ("3 days ago").
    /// Returns nil for non-timestamps or values that don't parse as ISO 8601.
    var relativeTimestamp: String? {
        guard case .timestamp(let iso) = self else { return nil }
        let date = Self.parseISO(iso)
        guard let date = date else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }

    private static func parseISO(_ s: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// String form used for case-insensitive `contains` matching.
    var searchableString: String {
        switch self {
        case .null: return ""
        case .boolean(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .timestamp(let s): return s
        case .string(let s): return s
        case .bytes(let s): return s
        case .reference(let s): return s
        case .geoPoint(let lat, let lng): return "\(lat),\(lng)"
        case .array(let arr): return arr.map { $0.searchableString }.joined(separator: ",")
        case .map(let f): return f.map { "\($0.name):\($0.value.searchableString)" }.joined(separator: ",")
        }
    }

    var typeLabel: String {
        switch self {
        case .null: return "null"
        case .boolean: return "bool"
        case .integer: return "int"
        case .double: return "double"
        case .timestamp: return "timestamp"
        case .string: return "string"
        case .bytes: return "bytes"
        case .reference: return "reference"
        case .geoPoint: return "geopoint"
        case .array: return "array"
        case .map: return "map"
        }
    }
}

enum FirestoreValueDecoder {
    /// Decodes a single Value object (as returned by Firestore REST).
    static func decode(_ obj: Any) -> FirestoreValue {
        guard let dict = obj as? [String: Any] else { return .null }
        if dict["nullValue"] != nil { return .null }
        if let b = dict["booleanValue"] as? Bool { return .boolean(b) }
        if let s = dict["integerValue"] as? String, let i = Int64(s) { return .integer(i) }
        if let n = dict["integerValue"] as? NSNumber { return .integer(n.int64Value) }
        if let d = dict["doubleValue"] as? Double { return .double(d) }
        if let s = dict["timestampValue"] as? String { return .timestamp(s) }
        if let s = dict["stringValue"] as? String { return .string(s) }
        if let s = dict["bytesValue"] as? String { return .bytes(s) }
        if let s = dict["referenceValue"] as? String { return .reference(s) }
        if let g = dict["geoPointValue"] as? [String: Any] {
            let lat = (g["latitude"] as? NSNumber)?.doubleValue ?? 0
            let lng = (g["longitude"] as? NSNumber)?.doubleValue ?? 0
            return .geoPoint(lat, lng)
        }
        if let arr = dict["arrayValue"] as? [String: Any] {
            let values = (arr["values"] as? [Any]) ?? []
            return .array(values.map(decode))
        }
        if let map = dict["mapValue"] as? [String: Any] {
            let fields = (map["fields"] as? [String: Any]) ?? [:]
            return .map(decodeFields(fields))
        }
        return .null
    }

    /// Decodes a full document `.fields` object into ordered fields (sorted by name for stability).
    static func decodeFields(_ fields: [String: Any]) -> [FirestoreField] {
        fields.keys.sorted().map { k in FirestoreField(name: k, value: decode(fields[k] as Any)) }
    }
}
