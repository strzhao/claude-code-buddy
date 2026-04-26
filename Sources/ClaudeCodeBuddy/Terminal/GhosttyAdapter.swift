import AppKit

class GhosttyAdapter: TerminalAdapter {

    func canHandle(bundleIdentifier: String) -> Bool {
        return bundleIdentifier.contains("ghostty")
    }

    func activateTab(for session: SessionInfo) -> Bool {
        clickLog("GhosttyAdapter.activateTab — terminalId: \(session.terminalId ?? "NIL"), cwd: \(session.cwd ?? "NIL")")
        if let terminalId = session.terminalId {
            clickLog("Trying activateByTerminalId: \(terminalId)")
            if activateByTerminalId(terminalId) {
                clickLog("activateByTerminalId SUCCESS")
                return true
            }
            clickLog("activateByTerminalId FAILED")
        }
        if let cwd = session.cwd {
            clickLog("Trying activateByCwd: \(cwd)")
            if activateByCwd(cwd) {
                clickLog("activateByCwd SUCCESS")
                return true
            }
            clickLog("activateByCwd FAILED")
        }
        clickLog("Falling back to activateGhosttyOnly")
        return activateGhosttyOnly()
    }

    // MARK: - Activation Strategies

    private func activateByTerminalId(_ terminalId: String) -> Bool {
        let script = """
        tell application "Ghostty"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with tm in terminals of t
                if id of tm is "\(terminalId)" then
                  delay 0.3
                  tell application "System Events"
                    tell process "Ghostty"
                      set frontmost to true
                    end tell
                  end tell
                  focus tm
                  return true
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error = error {
                clickLog("activateByTerminalId AppleScript error: \(error)")
                return false
            }
            let success = result.booleanValue
            clickLog("activateByTerminalId AppleScript result: \(success)")
            return success
        }
        clickLog("activateByTerminalId failed to create NSAppleScript")
        return false
    }

    private func activateByCwd(_ cwd: String) -> Bool {
        let escapedCwd = cwd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with tm in terminals of t
                if working directory of tm is "\(escapedCwd)" then
                  delay 0.3
                  tell application "System Events"
                    tell process "Ghostty"
                      set frontmost to true
                    end tell
                  end tell
                  focus tm
                  return true
                end if
              end repeat
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
        return false
    }

    func setTabTitle(for session: SessionInfo) -> Bool {
        let title = "●\(session.label)"

        if let terminalId = session.terminalId {
            let script = """
            tell application "Ghostty"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with tm in terminals of t
                    if id of tm is "\(terminalId)" then
                      perform action "set_tab_title:\(title)" on tm
                      return true
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return false
            """
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if error == nil { return true }
            }
        }

        // Fallback: match by cwd
        if let cwd = session.cwd {
            let escapedCwd = cwd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "Ghostty"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with tm in terminals of t
                    if working directory of tm is "\(escapedCwd)" then
                      perform action "set_tab_title:\(title)" on tm
                      return true
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return false
            """
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                return error == nil
            }
        }

        return false
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
