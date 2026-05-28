import Foundation
import AVFoundation
import WhisperKit

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

    // Stream support
    private var streamContinuation: AsyncThrowingStream<[Float], Error>.Continuation?
    public var audioStream: AsyncThrowingStream<[Float], Error>?

    // State
    private var usingLegacyMode = false
    @Published var isRecording = false

    // MARK: - VAD-powered auto-stop
    //
    // Detects sustained silence after the user has spoken, then fires `onAutoStop` exactly
    // once. Only active in non-legacy modes (legacy has no live sample stream).
    private var vad: EnergyVAD?
    private var vadEnabled: Bool = false
    private var vadSilenceThresholdSec: Double = 5.0
    private var vadHasSpoken: Bool = false
    private var vadLastVoiceTime: Date?
    private var vadFired: Bool = false
    private var vadFrameAccumulator: [Float] = []
    // EnergyVAD's default frame length is 0.1s at 16 kHz = 1600 samples. We match that
    // so voiceActivity(in:) returns one bool per frame cleanly.
    private let vadFrameSize = 1600

    /// Called on MainActor when sustained silence exceeds the configured threshold AND the
    /// user has spoken at least once since `startRecording`. Fires at most once per session.
    var onAutoStop: (() -> Void)?
    
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
    
    func startRecording(
        useLegacy: Bool,
        autoStopEnabled: Bool = false,
        autoStopSilenceSeconds: Double = 5.0
    ) throws {
        audioSamples.removeAll()
        usingLegacyMode = useLegacy

        // Reset VAD state every session. Auto-stop is silently skipped in legacy mode
        // because that path doesn't deliver live samples to analyze.
        vadEnabled = autoStopEnabled && !useLegacy
        vadSilenceThresholdSec = autoStopSilenceSeconds
        vadHasSpoken = false
        vadLastVoiceTime = nil
        vadFired = false
        vadFrameAccumulator.removeAll(keepingCapacity: true)
        vad = vadEnabled ? EnergyVAD() : nil

        if useLegacy {
            print("Starting Legacy AudioRecorder (File-based)...")
            try startLegacyRecording()
        } else {
            print("Starting AVCaptureSession AudioRecorder (Memory-based)...")
            // Initialize stream
            let stream = AsyncThrowingStream<[Float], Error> { continuation in
                self.streamContinuation = continuation
            }
            self.audioStream = stream
            try startMemoryRecording()
        }
        
        isRecording = true
    }
    
    func stopRecording() async -> [Float] {
        // Silence VAD before tearing down the audio pipeline so any straggling sample
        // callback can't fire onAutoStop after a user-initiated stop.
        vadEnabled = false
        vadFired = true

        if usingLegacyMode {
            stopLegacyRecording()
        } else {
            await stopMemoryRecording()
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
    
    private func stopMemoryRecording() async {
        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil

        // AVCaptureSession has internal buffering — after stopRunning, late sample
        // buffers can still arrive on the audio dispatch queue and dispatch their
        // MainActor follow-ups (which both append to audioSamples AND yield to the
        // stream). Yielding here gives those tasks a chance to run before we close
        // the stream and before the caller reads audioSamples. Fixes the
        // "missing trailing 1-2 words" symptom in both Boost (stream stays open) and
        // Standard (audioSamples completes) modes.
        try? await Task.sleep(nanoseconds: 300 * 1_000_000)

        streamContinuation?.finish()
        streamContinuation = nil
        audioStream = nil
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
            // print("Yielding \(resampled.count) samples to stream")
            self.streamContinuation?.yield(resampled)
            self.feedVAD(resampled)
        }
    }

    // MARK: - VAD feed
    //
    // The countdown only starts AFTER first detected voice — so hitting the hotkey and
    // then thinking for a moment before speaking doesn't trip the timer. Brief mid-speech
    // pauses (a few hundred ms) never trip it because we reset `vadLastVoiceTime` on every
    // frame that contains voice.
    private func feedVAD(_ samples: [Float]) {
        guard vadEnabled, !vadFired, let vad else { return }
        vadFrameAccumulator.append(contentsOf: samples)

        // Process complete frames only. EnergyVAD returns one Bool per `vadFrameSize`-sized
        // chunk; partial frames carry over to the next call.
        let frameCount = vadFrameAccumulator.count / vadFrameSize
        guard frameCount > 0 else { return }
        let consumeCount = frameCount * vadFrameSize
        let processable = Array(vadFrameAccumulator.prefix(consumeCount))
        vadFrameAccumulator.removeFirst(consumeCount)

        let activity = vad.voiceActivity(in: processable)
        if activity.contains(true) {
            vadHasSpoken = true
            vadLastVoiceTime = Date()
        } else if vadHasSpoken, let last = vadLastVoiceTime {
            if Date().timeIntervalSince(last) >= vadSilenceThresholdSec {
                vadFired = true
                onAutoStop?()
            }
        }
    }

    // MARK: - AVAudioRecorder Delegate
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {}
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Legacy recorder error: \(String(describing: error))")
    }
}
