import Foundation

// MARK: - BuddyError

/// Unified error type for Claude Code Buddy.
/// Covers socket IPC, file I/O, and message decoding failure domains.
enum BuddyError: Error, CustomStringConvertible {

    // Socket
    case socketCreateFailed(reason: String)
    case socketBindFailed(path: String, reason: String)
    case socketListenFailed(reason: String)
    case socketAcceptFailed(reason: String)

    // Session
    case colorFileWriteFailed(path: String, reason: String)

    // Decode
    case messageDecodeFailed(raw: String, underlying: Error)

    var description: String {
        switch self {
        case .socketCreateFailed(let reason):
            return "Socket creation failed: \(reason)"
        case .socketBindFailed(let path, let reason):
            return "Socket bind failed at \(path): \(reason)"
        case .socketListenFailed(let reason):
            return "Socket listen failed: \(reason)"
        case .socketAcceptFailed(let reason):
            return "Socket accept failed: \(reason)"
        case .colorFileWriteFailed(let path, let reason):
            return "Color file write failed at \(path): \(reason)"
        case .messageDecodeFailed(let raw, let underlying):
            return "Message decode failed for '\(raw)': \(underlying)"
        }
    }
}
