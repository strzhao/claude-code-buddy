import AVFoundation
import Foundation

// MARK: - SpeechSynthesizerProtocol

/// Abstraction over AVSpeechSynthesizer for injectable testing.
/// Conformance is via the closed class + this protocol; production uses `AVSpeechSynthesizerAdapter`.
protocol SpeechSynthesizerProtocol {
    /// Speak the given text with the given locale.
    func speak(text: String, locale: String)
    /// Stop any ongoing speech immediately.
    func stopSpeaking()
}

// MARK: - Production adapter

/// Wraps `AVSpeechSynthesizer` as a `SpeechSynthesizerProtocol`.
final class AVSpeechSynthesizerAdapter: SpeechSynthesizerProtocol {
    private let inner: AVSpeechSynthesizer

    init(inner: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.inner = inner
    }

    func speak(text: String, locale: String) {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: locale)
        inner.speak(utt)
    }

    func stopSpeaking() {
        inner.stopSpeaking(at: .immediate)
    }
}

// MARK: - SpeechService

/// TTS service.  Singleton for production; inject a mock synth in tests.
/// Not @MainActor — AVSpeechSynthesizer handles its own thread safety.
final class SpeechService {
    static let shared = SpeechService()

    private let synth: SpeechSynthesizerProtocol

    /// Production init: uses a fresh `AVSpeechSynthesizerAdapter`.
    convenience init() {
        self.init(synth: AVSpeechSynthesizerAdapter())
    }

    /// Testable init: inject any `SpeechSynthesizerProtocol` implementation.
    init(synth: SpeechSynthesizerProtocol) {
        self.synth = synth
    }

    /// Convenience init accepting a raw `AVSpeechSynthesizer` (for backward compat with tests
    /// that subclass `AVSpeechSynthesizer` directly).
    init(synth: AVSpeechSynthesizer) {
        self.synth = AVSpeechSynthesizerAdapter(inner: synth)
    }

    /// Speaks `text` using the given `locale`.  Cancels any previous utterance first.
    func speak(_ text: String, locale: String = "en-US") {
        guard !text.isEmpty else { return }
        synth.stopSpeaking()
        synth.speak(text: text, locale: locale)
    }
}
