cask "claude-code-buddy" do
  version "0.2.0"
  sha256 "c5a623d9b7a4887a138f40188813787150b1bfc5a3de48509b187f463d993442"

  url "https://github.com/strzhao/claude-code-buddy/releases/download/v#{version}/ClaudeCodeBuddy-v#{version}.zip"
  name "Claude Code Buddy"
  desc "Pixel cat on your Dock that reflects Claude Code's working state"
  homepage "https://github.com/strzhao/claude-code-buddy"

  depends_on macos: ">= :sonoma"

  app "ClaudeCodeBuddy.app"

  zap trash: "~/Library/Preferences/com.claudebuddy.ClaudeCodeBuddy.plist"
end
