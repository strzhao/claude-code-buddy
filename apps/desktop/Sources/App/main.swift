import AppKit
import BuddyCore

// main.swift — SPM executable entry point
// Sets the app as an accessory process (no Dock icon), installs AppDelegate, runs.

// Per-app accent color = green（系统预设索引 3）。
// NSSwitch 等 AppKit 控件读系统级 accent（**不**读 Asset Catalog AccentColor），
// AppleAccentColor user default 在 app 域覆盖，NSSwitch 开态显示绿色。
// 注：AppleAccentColor 只接受系统预设色；sage 自定义需 subclass NSSwitch 自绘。
UserDefaults.standard.set(3, forKey: "AppleAccentColor")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
