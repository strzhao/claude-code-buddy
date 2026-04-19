import Foundation
import Combine

/// Single source of truth for the global EntityMode.
/// Persisted as JSON at ~/Library/Application Support/ClaudeCodeBuddy/settings.json.
/// Env var BUDDY_ENTITY (cat|rocket) overrides at init time for test automation.
final class EntityModeStore {

    static let shared = EntityModeStore()

    /// Emits current mode. CurrentValueSubject ensures new subscribers get the latest value immediately.
    let publisher: CurrentValueSubject<EntityMode, Never>

    private let settingsURL: URL
    private struct Payload: Codable { var entityMode: String }

    private init() {
        let url = Self.defaultSettingsURL()
        self.settingsURL = url
        let initial = Self.loadInitial(url: url,
                                       envOverride: ProcessInfo.processInfo.environment["BUDDY_ENTITY"])
        self.publisher = CurrentValueSubject(initial)
    }

    /// Test-only initializer.
    init(settingsURL: URL, envOverride: String? = nil) {
        self.settingsURL = settingsURL
        let initial = Self.loadInitial(url: settingsURL, envOverride: envOverride)
        self.publisher = CurrentValueSubject(initial)
    }

    var current: EntityMode { publisher.value }

    func set(_ mode: EntityMode) {
        guard publisher.value != mode else { return }
        persist(mode)
        publisher.send(mode)
    }

    // MARK: - Private

    private static func defaultSettingsURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ClaudeCodeBuddy")
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private static func loadInitial(url: URL, envOverride: String?) -> EntityMode {
        if let raw = envOverride, let mode = EntityMode(rawValue: raw) {
            return mode
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let mode = EntityMode(rawValue: payload.entityMode)
        else {
            return .cat
        }
        return mode
    }

    private func persist(_ mode: EntityMode) {
        let payload = Payload(entityMode: mode.rawValue)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}
