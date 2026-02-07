import Foundation
import AVFoundation

@MainActor
class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private let temporaryAudioURL: URL
    
    @Published var isRecording = false
    
    override init() {
        self.temporaryAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
        super.init()
    }
    
    nonisolated func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    func startRecording() throws {
        // Settings for Whisper: 16kHz, Mono, 16-bit PCM
        // This format is standard and widely supported, avoiding the crashes associated with
        // raw AVAudioEngine taps on input nodes.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        // Ensure the directory exists (temp dir always should, but good practice)
        // Cleanup old file
        try? FileManager.default.removeItem(at: temporaryAudioURL)
        
        let recorder = try AVAudioRecorder(url: temporaryAudioURL, settings: settings)
        recorder.delegate = self
        
        if recorder.prepareToRecord() {
            recorder.record()
            self.audioRecorder = recorder
            self.isRecording = true
            print("AudioRecorder started recording to \(temporaryAudioURL.path)")
        } else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare recorder"])
        }
    }
    
    func stopRecording() -> URL {
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        print("AudioRecorder stopped")
        return temporaryAudioURL
    }
    
    // MARK: - AVAudioRecorderDelegate
    
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("AudioRecorder finished unsuccessfully")
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("AudioRecorder encode error: \(error)")
        }
    }
}
