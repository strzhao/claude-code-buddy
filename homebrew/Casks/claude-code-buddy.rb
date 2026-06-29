cask "claude-code-buddy" do
  version "0.37.6"
  sha256 "81bc6d6746c99fd667308c8954276983de3be44fbc92db96902b7c675e972493"

  url "https://github.com/strzhao/claude-code-buddy/releases/download/v#{version}/ClaudeCodeBuddy-v#{version}.zip"
  name "Claude Code Buddy"
  desc "Pixel cat on your Dock that reflects Claude Code's working state"
  homepage "https://github.com/strzhao/claude-code-buddy"

  depends_on macos: :sonoma

  app "ClaudeCodeBuddy.app"

  binary "#{appdir}/ClaudeCodeBuddy.app/Contents/MacOS/buddy"

  zap trash: [
    "~/Library/Preferences/com.claudebuddy.ClaudeCodeBuddy.plist",
  ]
end
