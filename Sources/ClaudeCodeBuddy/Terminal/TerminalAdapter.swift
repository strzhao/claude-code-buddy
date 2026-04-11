import Foundation

protocol TerminalAdapter {
    func canHandle(bundleIdentifier: String) -> Bool
    func activateTab(for session: SessionInfo) -> Bool
}
