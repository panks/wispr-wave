import Foundation

/// The speech-to-text backends the app can run.
enum SpeechEngine: String, Codable, CaseIterable {
    case whisper, parakeet
}

/// A loaded speech model that can turn 16 kHz mono samples into text.
/// ModelManager holds at most one of these at a time.
@MainActor
protocol TranscriptionEngine: AnyObject {
    var kind: SpeechEngine { get }
    func transcribe(samples: [Float]) async throws -> String
    func unload() async
}
