import AppKit

class GhosttyAdapter: TerminalAdapter {

    func canHandle(bundleIdentifier: String) -> Bool {
        return bundleIdentifier.contains("ghostty")
    }

    func activateTab(for session: SessionInfo) -> Bool {
        guard let terminalId = session.terminalId else {
            return activateGhosttyOnly()
        }

        let script = """
        tell application "Ghostty"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              set term to focused terminal of t
              if id of term is "\(terminalId)" then
                delay 0.3
                tell application "System Events"
                  tell process "Ghostty"
                    set frontmost to true
                  end tell
                end tell
                focus term
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil && result.booleanValue {
                return true
            }
        }

        return activateGhosttyOnly()
    }

    func setTabTitle(for session: SessionInfo) -> Bool {
        guard let terminalId = session.terminalId else { return false }

        let title = "●\(session.label)"
        let script = """
        tell application "Ghostty"
          repeat with w in windows
            repeat with t in tabs of w
              set term to focused terminal of t
              if id of term is "\(terminalId)" then
                perform action "set_tab_title:\(title)" on term
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
        return error == nil
    }

    // MARK: - Private

    private func activateGhosttyOnly() -> Bool {
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first {
            return app.activate()
        }
        return false
    }
}
