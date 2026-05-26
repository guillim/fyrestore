import SwiftUI

enum Theme {
    static let bg = Color(nsColor: NSColor(calibratedRed: 0.984, green: 0.980, blue: 0.969, alpha: 1))
    static let panel = Color(nsColor: .textBackgroundColor)
    static let textPrimary = Color(nsColor: NSColor(calibratedRed: 0.216, green: 0.208, blue: 0.184, alpha: 1))
    static let textMuted = Color(nsColor: NSColor(calibratedRed: 0.471, green: 0.451, blue: 0.451, alpha: 1))
    static let divider = Color(nsColor: NSColor(calibratedRed: 0.922, green: 0.922, blue: 0.910, alpha: 1))
    static let accent = Color(nsColor: NSColor(calibratedRed: 0.137, green: 0.451, blue: 0.706, alpha: 1))
    /// Neutral pale chip used for affordances like sub-collection pills.
    static let typeChip = Color(nsColor: NSColor(calibratedRed: 0.961, green: 0.953, blue: 0.937, alpha: 1))

    /// Per-type colors for field type chips. Background is intentionally very pale,
    /// foreground is a deeper variant of the same hue. Designed to add scan-ability
    /// without visually competing with field names/values.
    static func chipColors(for typeLabel: String) -> (bg: Color, fg: Color) {
        switch typeLabel {
        case "string":     return (rgb(0.88, 0.93, 1.00), rgb(0.20, 0.40, 0.65))   // pale blue
        case "int", "double":
                           return (rgb(0.90, 0.96, 0.91), rgb(0.20, 0.50, 0.30))   // pale green
        case "bool":       return (rgb(0.99, 0.95, 0.85), rgb(0.65, 0.45, 0.10))   // pale amber
        case "timestamp":  return (rgb(0.93, 0.89, 0.99), rgb(0.45, 0.30, 0.60))   // pale purple
        case "reference":  return (rgb(0.88, 0.91, 1.00), rgb(0.25, 0.35, 0.60))   // pale indigo
        case "geopoint":   return (rgb(0.85, 0.95, 0.94), rgb(0.15, 0.45, 0.45))   // pale teal
        case "array":      return (rgb(0.99, 0.89, 0.93), rgb(0.65, 0.35, 0.50))   // pale coral
        case "map":        return (rgb(0.99, 0.87, 0.87), rgb(0.65, 0.30, 0.30))   // pale rose
        case "bytes":      return (rgb(0.94, 0.94, 0.94), rgb(0.40, 0.40, 0.40))   // gray
        case "null":       return (rgb(0.94, 0.94, 0.94), rgb(0.55, 0.55, 0.55))   // muted gray
        default:           return (rgb(0.94, 0.94, 0.94), rgb(0.45, 0.45, 0.45))
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(nsColor: NSColor(calibratedRed: r, green: g, blue: b, alpha: 1))
    }
}
