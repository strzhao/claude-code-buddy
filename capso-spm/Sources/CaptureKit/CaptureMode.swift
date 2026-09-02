// Packages/CaptureKit/Sources/CaptureKit/CaptureMode.swift
import Foundation
import CoreGraphics

public enum CaptureMode: String, Sendable {
    case area
    case fullscreen
    case window
    case scrolling
}

public struct CaptureResult: Sendable {
    public let image: CGImage
    public let mode: CaptureMode
    public let captureRect: CGRect
    public let windowName: String?
    public let appName: String?
    public let appBundleIdentifier: String?
    public let timestamp: Date
    /// The display where this capture originated.
    public let displayID: CGDirectDisplayID

    public init(
        image: CGImage,
        mode: CaptureMode,
        captureRect: CGRect,
        windowName: String? = nil,
        appName: String? = nil,
        appBundleIdentifier: String? = nil,
        timestamp: Date = Date(),
        displayID: CGDirectDisplayID = CGMainDisplayID()
    ) {
        self.image = image
        self.mode = mode
        self.captureRect = captureRect
        self.windowName = windowName
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.timestamp = timestamp
        self.displayID = displayID
    }
}
