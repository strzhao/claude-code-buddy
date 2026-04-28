cask "claude-code-buddy" do
  version "0.18.0"
  sha256 "324cd0fe47b278d5b841c8b8f2e7273cf6c831ded5697684bdf208a25bd1ea58"

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
