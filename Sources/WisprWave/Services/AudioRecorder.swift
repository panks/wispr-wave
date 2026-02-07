import Foundation
import AVFoundation

@MainActor
class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVAudioRecorderDelegate {
    // Primary (AVCaptureSession)
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    
    // Legacy (AVAudioRecorder)
    private var audioRecorder: AVAudioRecorder?
    private let temporaryAudioURL: URL
    
    // Store audio samples in memory
    private var audioSamples: [Float] = []
    
    // State
    private var usingLegacyMode = false
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
    
    func startRecording(useLegacy: Bool) throws {
        audioSamples.removeAll()
        usingLegacyMode = useLegacy
        
        if useLegacy {
            print("Starting Legacy AudioRecorder (File-based)...")
            try startLegacyRecording()
        } else {
            print("Starting AVCaptureSession AudioRecorder (Memory-based)...")
            try startMemoryRecording()
        }
        
        isRecording = true
    }
    
    func stopRecording() -> [Float] {
        if usingLegacyMode {
            stopLegacyRecording()
        } else {
            stopMemoryRecording()
        }
        
        isRecording = false
        print("Recording stopped. Samples captured: \(audioSamples.count)")
        return audioSamples
    }
    
    // MARK: - Legacy Implementation
    
    private func startLegacyRecording() throws {
        // Cleanup old file
        try? FileManager.default.removeItem(at: temporaryAudioURL)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        let recorder = try AVAudioRecorder(url: temporaryAudioURL, settings: settings)
        recorder.delegate = self
        
        if recorder.prepareToRecord() {
            recorder.record()
            self.audioRecorder = recorder
        } else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare legacy recorder"])
        }
    }
    
    private func stopLegacyRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        
        // Read file and convert to [Float]
        do {
            let samples = try readAudioFile(url: temporaryAudioURL)
            self.audioSamples = samples
        } catch {
            print("Error reading legacy audio file: \(error)")
            self.audioSamples = []
        }
    }
    
    private func readAudioFile(url: URL) throws -> [Float] {
        print("Reading legacy audio file from: \(url.path)")
        let file = try AVAudioFile(forReading: url)
        // processingFormat should be Float32 non-interleaved
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        
        try file.read(into: buffer)
        
        if let floatChannelData = buffer.floatChannelData {
            let channelPointer = floatChannelData.pointee
            return Array(UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength)))
        }
        return []
    }
    
    // MARK: - Memory Implementation
    
    private func startMemoryRecording() throws {
        let session = AVCaptureSession()
        self.captureSession = session
        
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio device found"])
        }
        
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        } else {
             throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not add audio input"])
        }
        
        let output = AVCaptureAudioDataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
             throw NSError(domain: "AudioRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not add audio output"])
        }
        
        self.audioOutput = output
        
        let queue = DispatchQueue(label: "com.wisprwave.audioQueue")
        output.setSampleBufferDelegate(self, queue: queue)
        
        Task.detached {
            session.startRunning()
        }
    }
    
    private func stopMemoryRecording() {
        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
    }
    
    // MARK: - AVCapture Delegate
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return
        }
        
        let samplesCount = CMSampleBufferGetNumSamples(sampleBuffer)
        if samplesCount == 0 { return }
        
        var bufferLength = 0
        var bufferData: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &bufferLength, dataPointerOut: &bufferData)
        
        guard let ptr = bufferData else { return }
        
        let channels = Int(asbd.mChannelsPerFrame)
        let count = bufferLength / 4
        
        let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: count) { $0 }
        let floats = Array(UnsafeBufferPointer(start: floatPtr, count: count))
        
        var resampled: [Float] = []
        
        // Simple downsampling or pass-through
        let strideVal = (asbd.mSampleRate >= 44000) ? (3 * channels) : channels
        
        for i in stride(from: 0, to: count, by: strideVal) {
            if i < count {
                resampled.append(floats[i])
            }
        }
        
        Task { @MainActor in
            self.audioSamples.append(contentsOf: resampled)
        }
    }
    
    // MARK: - AVAudioRecorder Delegate
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {}
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Legacy recorder error: \(String(describing: error))")
    }
}
