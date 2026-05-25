import Foundation

enum LauncherError: Error, LocalizedError {
    case hotkeyConflict(String)
    // future cases added by tasks 002-006:
    // case providerNotConfigured, invalidAPIKey, networkFailure(Error), ...

    var errorDescription: String? {
        switch self {
        case .hotkeyConflict(let combo):
            return "快捷键 \(combo) 被其他应用占用，请在设置中更改"
        }
    }
}
