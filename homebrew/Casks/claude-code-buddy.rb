cask "claude-code-buddy" do
  version "0.17.0"
  sha256 "38ae504af10174966be55a7b3c49d363ac719c46256b611781e75191785973ca"

  url "https://github.com/strzhao/claude-code-buddy/releases/download/v#{version}/ClaudeCodeBuddy-v#{version}.zip"
  name "Claude Code Buddy"
  desc "Pixel cat on your Dock that reflects Claude Code's working state"
  homepage "https://github.com/strzhao/claude-code-buddy"

  depends_on macos: ">= :sonoma"

  app "ClaudeCodeBuddy.app"

  binary "#{appdir}/ClaudeCodeBuddy.app/Contents/MacOS/buddy"

  zap trash: [
    "~/Library/Preferences/com.claudebuddy.ClaudeCodeBuddy.plist",
  ]
end
