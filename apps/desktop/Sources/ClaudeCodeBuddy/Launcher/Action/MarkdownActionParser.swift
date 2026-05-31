import Foundation

/// Preprocesses markdown strings containing `<action:HANDLER ...>label</action>` tags
/// into an array of `ActionSegment` values.
///
/// Contract C1 / C2: unknown handlers, missing `text` attribute, and unclosed tags are
/// silently discarded (soft-fail). No raw tag text leaks into output.
enum MarkdownActionParser {

    // Regex: matches ANY closed action tag (with or without attributes)
    // Group 1: handler name
    // Group 2: full attribute string (optional — absent when no attributes)
    // Group 3: label (may contain inner tags — treated as plain string)
    // Matches:
    //   <action:speak text="x">label</action>  -- valid
    //   <action:speak>label</action>            -- no text attr → discarded
    private static let tagPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<action:([a-z]+)(\s[^>]*)?>([^<]*(?:<(?!/action>)[^<]*)*)</action>"#,
            options: []
        )
    }()

    private static let attrPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"([a-zA-Z]+)="([^"]*)"#,
            options: []
        )
    }()

    /// Parses `raw` markdown and returns an array of `ActionSegment` values.
    /// Segments preserve the original text order. Unparseable action tags are dropped entirely.
    static func preprocess(_ raw: String) -> [ActionSegment] {
        var segments: [ActionSegment] = []
        let nsRaw = raw as NSString
        let fullRange = NSRange(location: 0, length: nsRaw.length)
        let matches = tagPattern.matches(in: raw, options: [], range: fullRange)

        var cursor = 0

        for match in matches {
            let matchRange = match.range

            // Text before this tag
            if matchRange.location > cursor {
                let textRange = NSRange(location: cursor, length: matchRange.location - cursor)
                let textPart = nsRaw.substring(with: textRange)
                if !textPart.isEmpty {
                    segments.append(.text(textPart))
                }
            }

            // Extract handler name
            let handlerRange = match.range(at: 1)
            guard handlerRange.location != NSNotFound else {
                cursor = matchRange.location + matchRange.length
                continue
            }
            let handlerStr = nsRaw.substring(with: handlerRange)

            // Resolve handler to enum (closed set)
            let handler: ActionHandler
            switch handlerStr {
            case "speak": handler = .speak
            case "copy":  handler = .copy
            default:
                // Unknown handler: discard whole tag (C2 row 1)
                cursor = matchRange.location + matchRange.length
                continue
            }

            // Extract attribute string
            let attrRange = match.range(at: 2)
            guard attrRange.location != NSNotFound else {
                cursor = matchRange.location + matchRange.length
                continue
            }
            let attrStr = nsRaw.substring(with: attrRange)

            // Parse attributes — v1 requires `text`
            let attrs = parseAttributes(attrStr)
            guard let textAttr = attrs["text"] else {
                // Missing text attribute: discard whole tag (C2 row 2)
                cursor = matchRange.location + matchRange.length
                continue
            }

            // Extract label
            let labelRange = match.range(at: 3)
            let label = labelRange.location != NSNotFound ? nsRaw.substring(with: labelRange) : ""

            segments.append(.action(handler: handler, text: textAttr, label: label))
            cursor = matchRange.location + matchRange.length
        }

        // Remaining text after last match
        if cursor < nsRaw.length {
            let remainder = nsRaw.substring(from: cursor)
            if !remainder.isEmpty {
                segments.append(.text(remainder))
            }
        }

        // Post-process: strip residual partial action tags from text segments
        // C2 contract: unclosed `<action:...>` tags must not appear as text
        return segments.compactMap { seg -> ActionSegment? in
            guard case .text(let raw) = seg else { return seg }
            let cleaned = stripPartialActionTags(raw)
            return cleaned.isEmpty ? nil : .text(cleaned)
        }
    }

    // MARK: - Private Helpers

    // Pattern to strip incomplete `<action:...` sequences and orphaned `</action>` from text
    private static let partialTagPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<action:[^>]*(?:>[^<]*)?(?:</action>)?|</action>"#,
            options: []
        )
    }()

    /// Removes any remaining `<action:...>` fragments from text (handles unclosed tags etc.)
    private static func stripPartialActionTags(_ text: String) -> String {
        partialTagPattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: ""
        )
    }

    /// Parses `key="value"` pairs from an attribute string.
    /// Unescapes `&quot;` → `"`, `&lt;` → `<`, `&gt;` → `>`.
    private static func parseAttributes(_ attrStr: String) -> [String: String] {
        var result: [String: String] = [:]
        let nsStr = attrStr as NSString
        let matches = attrPattern.matches(in: attrStr, options: [], range: NSRange(location: 0, length: nsStr.length))
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let keyRange = m.range(at: 1)
            let valRange = m.range(at: 2)
            guard keyRange.location != NSNotFound, valRange.location != NSNotFound else { continue }
            let key = nsStr.substring(with: keyRange)
            let rawVal = nsStr.substring(with: valRange)
            result[key] = unescape(rawVal)
        }
        return result
    }

    /// Decodes XML character entities used in attribute values.
    private static func unescape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
