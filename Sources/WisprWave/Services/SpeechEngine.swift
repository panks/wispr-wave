import Foundation

/// The speech-to-text backends the app can run.
enum SpeechEngine: String, Codable, CaseIterable {
    case whisper, parakeet

    /// Name shown in the popup's engine switch and status line.
    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }
}

/// A loaded speech model that can turn 16 kHz mono samples into text.
/// ModelManager holds at most one of these at a time.
@MainActor
protocol TranscriptionEngine: AnyObject {
    var kind: SpeechEngine { get }
    func transcribe(samples: [Float]) async throws -> String
    func unload() async
}
