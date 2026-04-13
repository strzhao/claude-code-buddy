import Foundation

/// Custom resource bundle finder that works in both .app bundles and SPM development builds.
///
/// SPM-generated `Bundle.module` uses `Bundle.main.bundleURL` (the .app root) to locate
/// the resource bundle, but macOS code signing forbids files at the .app root level.
/// This finder checks `Bundle.main.resourceURL` (`Contents/Resources/`) first, which
/// works for both .app distribution and SPM `swift build` development.
enum ResourceBundle {
    static let bundle: Bundle = {
        let bundleName = "ClaudeCodeBuddy_BuddyCore"

        // Contents/Resources/ for .app; executable directory for swift build
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent(bundleName + ".bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }

        // Fallback to SPM-generated accessor (absolute build path)
        return Bundle.module
    }()
}
