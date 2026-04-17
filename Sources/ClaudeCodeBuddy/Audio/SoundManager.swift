import AVFoundation
import Combine

final class SoundManager: NSObject, AVAudioPlayerDelegate {

    static let shared = SoundManager()

    private static let soundEnabledKey = "soundEnabled"
    private static let volume: Float = 0.3

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.soundEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.soundEnabledKey) }
    }

    private var player: AVAudioPlayer?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()

        EventBus.shared.stateChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                switch event.newState {
                case .taskComplete:
                    self?.playSound(for: \.taskComplete)
                case .permissionRequest:
                    self?.playSound(for: \.permissionRequest)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        SkinPackManager.shared.skinChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Stop any in-progress playback; next event will load from the new skin
                self?.player?.stop()
                self?.player = nil
            }
            .store(in: &cancellables)
    }

    private func playSound(for keyPath: KeyPath<SoundConfig, String?>) {
        guard isEnabled else { return }

        let skin = SkinPackManager.shared.activeSkin
        guard let soundConfig = skin.manifest.sounds,
              let filename = soundConfig[keyPath: keyPath] else { return }

        let nameWithoutExt = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.isEmpty ? "mp3" : (filename as NSString).pathExtension

        guard let url = skin.url(
            forResource: nameWithoutExt,
            withExtension: ext,
            subdirectory: soundConfig.resolvedDirectory
        ) else { return }

        do {
            player?.stop()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.volume = Self.volume
            newPlayer.delegate = self
            newPlayer.play()
            player = newPlayer
        } catch {
            // Silently ignore playback failures
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if self.player === player {
            self.player = nil
        }
    }
}
