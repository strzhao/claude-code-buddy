import AppKit

enum SessionColor: Int, CaseIterable {
    case coral, teal, gold, violet, mint, peach, sky, rose

    var hex: String {
        switch self {
        case .coral:  return "#FF6B6B"
        case .teal:   return "#4ECDC4"
        case .gold:   return "#FFD93D"
        case .violet: return "#6C5CE7"
        case .mint:   return "#00B894"
        case .peach:  return "#FD79A8"
        case .sky:    return "#74B9FF"
        case .rose:   return "#E17055"
        }
    }

    var nsColor: NSColor {
        // Parse hex string to NSColor
        let hex = self.hex.dropFirst() // remove #
        let scanner = Scanner(string: String(hex))
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    var ansi256: Int {
        switch self {
        case .coral:  return 204  // light red
        case .teal:   return 43   // cyan-ish
        case .gold:   return 220  // gold
        case .violet: return 99   // purple
        case .mint:   return 42   // green
        case .peach:  return 211  // pink
        case .sky:    return 111  // light blue
        case .rose:   return 173  // salmon
        }
    }
}
