import Foundation
@preconcurrency import AVFoundation

@MainActor
class AudioRecorder: ObservableObject {
    private var audioEngine: AVAudioEngine
    private var inputNode: AVAudioInputNode
    private var audioFile: AVAudioFile?
    private let temporaryAudioURL: URL
    
    @Published var isRecording = false
    
    init() {
        self.audioEngine = AVAudioEngine()
        self.inputNode = audioEngine.inputNode
        self.temporaryAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
    }
    
    func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    func startRecording() throws {
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Target format: 16kHz, Mono, PCM 16-bit
        let targetSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let targetFormat = AVAudioFormat(settings: targetSettings) else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Audio Format"])
        }
        
        // Prepare file for writing
        // Deleting old file
        try? FileManager.default.removeItem(at: temporaryAudioURL)
        audioFile = try AVAudioFile(forWriting: temporaryAudioURL, settings: targetSettings)
        
        // Setup Converter
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self, let audioFile = self.audioFile else { return }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            // Calculate output buffer size ratio
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = UInt32(Double(buffer.frameCapacity) * ratio)
            
            if let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) {
                converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
                
                if let error = error {
                    print("Conversion error: \(error)")
                    return
                }
                
                do {
                    try audioFile.write(from: outputBuffer)
                } catch {
                    print("Write error: \(error)")
                }
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        DispatchQueue.main.async { self.isRecording = true }
    }
    
    func stopRecording() -> URL {
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        audioFile = nil
        DispatchQueue.main.async { self.isRecording = false }
        return temporaryAudioURL
    }
}
