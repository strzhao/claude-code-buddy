cask "claude-code-buddy" do
  version "0.19.2"
  sha256 "ebcf974b1d6804a69f408ecd9ac10180453a34cd4648340d9dcc6673ca8ade98"

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
