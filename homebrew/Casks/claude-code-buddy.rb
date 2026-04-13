cask "claude-code-buddy" do
  version "0.4.5"
  sha256 "d72eeaa65abfdb7cd2c3905333674f3b5d9f35d40c0e01b4b6ce75c2c2adf32e"

  url "https://github.com/strzhao/claude-code-buddy/releases/download/v#{version}/ClaudeCodeBuddy-v#{version}.zip"
  name "Claude Code Buddy"
  desc "Pixel cat on your Dock that reflects Claude Code's working state"
  homepage "https://github.com/strzhao/claude-code-buddy"

  depends_on macos: ">= :sonoma"

  app "ClaudeCodeBuddy.app"

  zap trash: "~/Library/Preferences/com.claudebuddy.ClaudeCodeBuddy.plist"
end
