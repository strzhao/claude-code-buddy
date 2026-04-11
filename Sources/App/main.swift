import AppKit
import BuddyCore

// main.swift — SPM executable entry point
// Sets the app as an accessory process (no Dock icon), installs AppDelegate, runs.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
