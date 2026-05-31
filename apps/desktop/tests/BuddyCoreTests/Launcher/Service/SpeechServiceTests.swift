import AVFoundation
import XCTest
@testable import BuddyCore

// MARK: - Mock SpeechSynthesizerProtocol

/// Records calls without actually speaking.
final class MockSynthesizerForService: SpeechSynthesizerProtocol, @unchecked Sendable {
    private(set) var speakCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastSpokenText: String?
    private(set) var lastUsedLocale: String?

    func speak(text: String, locale: String) {
        speakCallCount += 1
        lastSpokenText = text
        lastUsedLocale = locale
    }

    func stopSpeaking() {
        stopCallCount += 1
    }
}

final class SpeechServiceTests: XCTestCase {

    func test_speak_calls_synthesizer() {
        let mock = MockSynthesizerForService()
        let svc = SpeechService(synth: mock)
        svc.speak("hello")
        XCTAssertEqual(mock.speakCallCount, 1)
        XCTAssertEqual(mock.lastSpokenText, "hello")
    }

    func test_speak_stops_previous_first() {
        let mock = MockSynthesizerForService()
        let svc = SpeechService(synth: mock)
        svc.speak("first")
        svc.speak("second")
        XCTAssertEqual(mock.stopCallCount, 2, "stopSpeaking should be called before each speak")
        XCTAssertEqual(mock.speakCallCount, 2)
        XCTAssertEqual(mock.lastSpokenText, "second")
    }

    func test_speak_empty_string_is_noop() {
        let mock = MockSynthesizerForService()
        let svc = SpeechService(synth: mock)
        svc.speak("")
        XCTAssertEqual(mock.speakCallCount, 0, "Empty string must not call speak")
    }

    func test_speak_default_locale_is_en_US() {
        let mock = MockSynthesizerForService()
        let svc = SpeechService(synth: mock)
        svc.speak("buddy")
        XCTAssertEqual(mock.lastUsedLocale, "en-US", "Default locale must be en-US")
    }

    func test_speak_custom_locale() {
        let mock = MockSynthesizerForService()
        let svc = SpeechService(synth: mock)
        svc.speak("你好", locale: "zh-CN")
        XCTAssertEqual(mock.speakCallCount, 1)
        XCTAssertEqual(mock.lastSpokenText, "你好")
        XCTAssertEqual(mock.lastUsedLocale, "zh-CN")
    }

    // MARK: - Scenario 4: TTS not auto-triggered

    func test_scenario4_P2_no_auto_speak_on_create() {
        let mock = MockSynthesizerForService()
        _ = SpeechService(synth: mock)
        // Just creating the service must not trigger any speaks
        XCTAssertEqual(mock.speakCallCount, 0, "4.P2: Service creation must not call speak")
    }
}
