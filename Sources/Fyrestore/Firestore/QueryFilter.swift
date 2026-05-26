import Foundation

/// A single-field filter for Firestore `runQuery`.
/// Syntax accepted by `parse`: `field op value`, e.g. `age >= 18`, `name == "alice"`, `active == true`.
struct QueryFilter: Equatable {
    enum Op: Equatable, CaseIterable, Hashable {
        case equal, notEqual, lessThan, lessOrEqual, greaterThan, greaterOrEqual
        case contains  // case-insensitive substring, evaluated client-side

        /// Firestore REST operator name (only meaningful for `isServerSide` ops).
        var firestoreOpName: String {
            switch self {
            case .equal: return "EQUAL"
            case .notEqual: return "NOT_EQUAL"
            case .lessThan: return "LESS_THAN"
            case .lessOrEqual: return "LESS_THAN_OR_EQUAL"
            case .greaterThan: return "GREATER_THAN"
            case .greaterOrEqual: return "GREATER_THAN_OR_EQUAL"
            case .contains: return ""
            }
        }

        /// User-facing textual symbol (also accepted by the advanced-mode parser).
        var symbol: String {
            switch self {
            case .equal: return "=="
            case .notEqual: return "!="
            case .lessThan: return "<"
            case .lessOrEqual: return "<="
            case .greaterThan: return ">"
            case .greaterOrEqual: return ">="
            case .contains: return "contains"
            }
        }

        /// Server-side ops translate to a Firestore `runQuery`. Client-side ops
        /// (currently just `contains`) are filtered locally over a fetched page.
        var isServerSide: Bool {
            switch self {
            case .contains: return false
            default: return true
            }
        }
    }

    enum Value: Equatable {
        case string(String)
        case integer(Int64)
        case double(Double)
        case boolean(Bool)

        var firestoreJSON: [String: Any] {
            switch self {
            case .string(let s): return ["stringValue": s]
            case .integer(let i): return ["integerValue": String(i)]
            case .double(let d): return ["doubleValue": d]
            case .boolean(let b): return ["booleanValue": b]
            }
        }

        /// Plain string form for client-side `contains` matching.
        var searchableString: String {
            switch self {
            case .string(let s): return s
            case .integer(let i): return String(i)
            case .double(let d): return String(d)
            case .boolean(let b): return b ? "true" : "false"
            }
        }
    }

    let field: String
    let op: Op
    let value: Value

    /// Parses one of: `field == value`, `field != value`, `field <= value`, `field >= value`,
    /// `field < value`, `field > value`. Value inference order: quoted string → bool → int → double → bare string.
    /// Returns nil on empty input. Throws on malformed input (so the UI can surface why).
    static func parse(_ text: String) throws -> QueryFilter? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Symbol operators first, longest-first to avoid `<=` being consumed by `<`.
        let symbolOps: [(String, Op)] = [
            ("==", .equal), ("!=", .notEqual),
            ("<=", .lessOrEqual), (">=", .greaterOrEqual),
            ("<", .lessThan), (">", .greaterThan)
        ]

        for (str, op) in symbolOps {
            if let range = trimmed.range(of: str) {
                let field = trimmed[trimmed.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let rawValue = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !field.isEmpty else { throw ParseError.missingField }
                guard !rawValue.isEmpty else { throw ParseError.missingValue }
                return QueryFilter(field: field, op: op, value: parseValue(String(rawValue)))
            }
        }

        // Word operator `contains` — must be a whole word so `containsField` doesn't trip it.
        if let range = trimmed.range(of: #"\bcontains\b"#, options: [.regularExpression, .caseInsensitive]) {
            let field = trimmed[trimmed.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !field.isEmpty else { throw ParseError.missingField }
            guard !rawValue.isEmpty else { throw ParseError.missingValue }
            return QueryFilter(field: field, op: .contains, value: parseValue(String(rawValue)))
        }

        throw ParseError.missingOperator
    }

    enum ParseError: LocalizedError {
        case missingField
        case missingValue
        case missingOperator

        var errorDescription: String? {
            switch self {
            case .missingField: return "Filter is missing a field name."
            case .missingValue: return "Filter is missing a value."
            case .missingOperator: return "Filter needs an operator (==, !=, <, <=, >, >=)."
            }
        }
    }

    /// Build a filter from three already-separated fields (basic mode in the UI).
    /// Returns nil if both field and value are empty (treated as "no filter").
    /// Throws `ParseError.missingField` / `.missingValue` if exactly one is empty.
    static func build(field: String, op: Op, rawValue: String) throws -> QueryFilter? {
        let f = field.trimmingCharacters(in: .whitespaces)
        let v = rawValue.trimmingCharacters(in: .whitespaces)
        if f.isEmpty && v.isEmpty { return nil }
        if f.isEmpty { throw ParseError.missingField }
        if v.isEmpty { throw ParseError.missingValue }
        return QueryFilter(field: f, op: op, value: parseValue(v))
    }

    static func parseValue(_ raw: String) -> Value {
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2) ||
           (raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2) {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if let i = Int64(raw) { return .integer(i) }
        if let d = Double(raw) { return .double(d) }
        return .string(raw)
    }
}
