import AppKit

class GhosttyAdapter: TerminalAdapter {

    func canHandle(bundleIdentifier: String) -> Bool {
        return bundleIdentifier.contains("ghostty")
    }

    func activateTab(for session: SessionInfo) -> Bool {
        // Try matching by ●label in tab title
        let script = """
        tell application "Ghostty"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              set term to focused terminal of t
              if name of term contains "●\(session.label)" then
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
            if error == nil {
                return result.booleanValue
            }
        }

        // Fallback: activate by PID
        if let pid = session.pid {
            return activateByPID(pid)
        }

        return false
    }

    private func activateByPID(_ pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        return app.activate()
    }
}
