import Foundation

// MARK: - TokenLevel

/// Discrete growth levels driven by cumulative token usage.
/// Each level maps to a visual scale factor and required window height.
/// 16 levels with gradual growth — Lv16 at 100M+ tokens reaches 1.35x max.
enum TokenLevel: Int, CaseIterable, Comparable {
    case lv1 = 1
    case lv2 = 2
    case lv3 = 3
    case lv4 = 4
    case lv5 = 5
    case lv6 = 6
    case lv7 = 7
    case lv8 = 8
    case lv9 = 9
    case lv10 = 10
    case lv11 = 11
    case lv12 = 12
    case lv13 = 13
    case lv14 = 14
    case lv15 = 15
    case lv16 = 16

    // MARK: - Thresholds

    /// Minimum token count to reach this level.
    var threshold: Int {
        switch self {
        case .lv1:  return 0
        case .lv2:  return 100_000
        case .lv3:  return 300_000
        case .lv4:  return 500_000
        case .lv5:  return 800_000
        case .lv6:  return 1_200_000
        case .lv7:  return 2_000_000
        case .lv8:  return 3_000_000
        case .lv9:  return 5_000_000
        case .lv10: return 7_000_000
        case .lv11: return 10_000_000
        case .lv12: return 15_000_000
        case .lv13: return 20_000_000
        case .lv14: return 30_000_000
        case .lv15: return 50_000_000
        case .lv16: return 100_000_000
        }
    }

    /// Scale factor applied to containerNode.
    var scale: CGFloat {
        switch self {
        case .lv1:  return 1.00
        case .lv2:  return 1.02
        case .lv3:  return 1.05
        case .lv4:  return 1.07
        case .lv5:  return 1.10
        case .lv6:  return 1.12
        case .lv7:  return 1.15
        case .lv8:  return 1.17
        case .lv9:  return 1.19
        case .lv10: return 1.21
        case .lv11: return 1.23
        case .lv12: return 1.26
        case .lv13: return 1.28
        case .lv14: return 1.30
        case .lv15: return 1.33
        case .lv16: return 1.35
        }
    }

    /// Required window height (pt) to fully display a cat at this level.
    var windowHeight: CGFloat {
        switch self {
        case .lv1:  return 80
        case .lv2:  return 82
        case .lv3:  return 84
        case .lv4:  return 86
        case .lv5:  return 88
        case .lv6:  return 90
        case .lv7:  return 92
        case .lv8:  return 93
        case .lv9:  return 95
        case .lv10: return 97
        case .lv11: return 98
        case .lv12: return 100
        case .lv13: return 102
        case .lv14: return 104
        case .lv15: return 106
        case .lv16: return 108
        }
    }

    // MARK: - Lookup

    /// Determine the token level for a given cumulative token count.
    /// Clamps negative values to Lv1.
    static func from(totalTokens: Int) -> TokenLevel {
        let tokens = max(0, totalTokens)
        // Walk levels in descending order to find the highest matching threshold
        for level in Self.allCases.reversed() where tokens >= level.threshold {
            return level
        }
        return .lv1
    }

    // MARK: - Display

    /// Short display name, e.g. "Lv3".
    var displayName: String {
        "Lv\(rawValue)"
    }

    /// Format token count for display, e.g. "1.2M".
    static func formatTokens(_ tokens: Int) -> String {
        let clamped = max(0, tokens)
        if clamped < 1000 {
            return "\(clamped)"
        } else if clamped < 1_000_000 {
            let k = Double(clamped) / 1000.0
            return k < 100 ? String(format: "%.1fK", k) : String(format: "%.0fK", k)
        } else {
            let m = Double(clamped) / 1_000_000.0
            return m < 10 ? String(format: "%.1fM", m) : String(format: "%.0fM", m)
        }
    }

    /// Level-up popup text, e.g. "1.2M tokens".
    func levelUpText(tokens: Int) -> String {
        "\(Self.formatTokens(tokens)) tokens"
    }

    /// Hover tooltip suffix, e.g. "1.2M tokens".
    func tooltipText(tokens: Int) -> String {
        "\(Self.formatTokens(tokens)) tokens"
    }

    // MARK: - Comparable

    static func < (lhs: TokenLevel, rhs: TokenLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
