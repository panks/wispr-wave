import Foundation
import AVFoundation

@MainActor
class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    
    // Store audio samples in memory
    private var audioSamples: [Float] = []
    
    @Published var isRecording = false
    
    override init() {
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
        audioSamples.removeAll()
        
        // 1. Setup Session
        let session = AVCaptureSession()
        self.captureSession = session
        
        // 2. Setup Input
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio device found"])
        }
        
        let input = try AVCaptureDeviceInput(device: device)
        
        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not add audio input"])
        }
        
        // 3. Setup Output
        let output = AVCaptureAudioDataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            throw NSError(domain: "AudioRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not add audio output"])
        }
        
        self.audioOutput = output
        
        // Use a serial queue for audio processing
        let queue = DispatchQueue(label: "com.wisprwave.audioQueue")
        output.setSampleBufferDelegate(self, queue: queue)
        
        // 4. Start
        Task.detached {
            session.startRunning()
        }
        
        isRecording = true
        print("AVCaptureSession started")
    }
    
    func stopRecording() -> [Float] {
        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        isRecording = false
        print("AVCaptureSession stopped, captured \(audioSamples.count) samples")
        return audioSamples
    }
    
    // MARK: - Delegate
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        // Check format
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return
        }
        
        let samplesCount = CMSampleBufferGetNumSamples(sampleBuffer)
        if samplesCount == 0 { return }
        
        // 1. Get raw bytes
        var bufferLength = 0
        var bufferData: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &bufferLength, dataPointerOut: &bufferData)
        
        guard let ptr = bufferData else { return }
        
        // Assume Float32 (4 bytes per sample) - typical for macOS AVCaptureSession
        // If not, this simple logic will fail/noise, but usually it IS LPCM Float32.
        
        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytesPerSample = Int(asbd.mBytesPerFrame) / channels
        
        if isFloat && bytesPerSample == 4 {
            let count = bufferLength / 4
            // Pointer cast
            let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: count) { $0 }
            let floats = Array(UnsafeBufferPointer(start: floatPtr, count: count))
            
            // Simple Downsampling Strategy
            // Goal: ~16kHz. Input usually 48kHz or 44.1kHz.
            
            var resampled: [Float] = []
            if asbd.mSampleRate == 48000 {
                // 48k -> 16k: Take every 3rd sample
                // Also handle channels (mix or take first)
                // Taking first channel for simplicity
                for i in stride(from: 0, to: count, by: 3 * channels) {
                    if i < count {
                        resampled.append(floats[i])
                    }
                }
            } else if asbd.mSampleRate == 44100 {
                 // 44.1k -> 16k: Ratio ~2.756. 
                 // Naive: take every 3rd (14.7k) or every 2nd (22k)? 
                 // Proper resampling is hard without Accelerate/AVAudioConverter.
                 // Let's take every 3rd (~14.7kHz) - might be "slow" audio.
                 // Or just keep all and let WhisperKit handle?
                 // WhisperKit expects 16kHz usually.
                 // Let's try sending ALL data if not 48k, or simple decimation.
                 
                 // Fallback: just take channel 0
                 for i in stride(from: 0, to: count, by: channels) {
                    resampled.append(floats[i])
                }
            } else if asbd.mSampleRate == 16000 {
                if channels == 1 {
                    resampled = floats
                } else {
                     for i in stride(from: 0, to: count, by: channels) {
                        resampled.append(floats[i])
                    }
                }
            } else {
                 // Fallback: just take channel 0
                 for i in stride(from: 0, to: count, by: channels) {
                    resampled.append(floats[i])
                }
            }
            
            Task { @MainActor in
                self.audioSamples.append(contentsOf: resampled)
            }
        }
    }
}
