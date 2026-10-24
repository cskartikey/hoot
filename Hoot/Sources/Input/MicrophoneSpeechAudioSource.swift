//
//  MicrophoneSpeechAudioSource.swift
//  Hoot
//
//  Captures the microphone and turns it into what AssemblyAI's streaming API
//  wants: 16 kHz, mono, signed 16-bit little-endian PCM, in ~50 ms chunks.
//  Also measures loudness for the listening bars.
//

import AVFoundation
import Foundation

/// Anything that can feed speech audio to `VoiceInputController`. The real app
/// uses the microphone; the test harness feeds a pre-recorded file instead, so
/// the whole hold → transcript → submit flow can be checked without a human.
///
/// Callbacks are always delivered on the main actor.
@MainActor
protocol SpeechAudioSource: AnyObject {
    /// Called with ~50 ms of 16 kHz mono PCM16 little-endian audio.
    var onAudioChunk: ((Data) -> Void)? { get set }
    /// Called with the raw (unsmoothed) loudness of the latest chunk, 0...1.
    var onAudioLevel: ((Float) -> Void)? { get set }
    /// Starts capturing (asking for permission first when needed). The
    /// completion says whether audio is now flowing.
    func startCapturing(completion: @escaping (_ didStartCapturing: Bool) -> Void)
    func stopCapturing()
}

/// Microphone capture with AVAudioEngine. One instance is used per hold: a
/// fresh engine every time picks up whichever input device is current (AirPods
/// connected since the last question, etc.) and avoids stale-engine bugs.
@MainActor
final class MicrophoneSpeechAudioSource: SpeechAudioSource {
    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private var runningAudioEngine: AVAudioEngine?
    /// Set by `stopCapturing`. A permission prompt can still be up when the
    /// learner lets go, and we must not start the mic after that.
    private var wasStoppedByCaller = false
    /// Chunks are hopped to the main thread asynchronously, so a few can land
    /// after `stopCapturing`. This flag drops them.
    private var isDeliveringAudio = false

    func startCapturing(completion: @escaping (_ didStartCapturing: Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(startAudioEngine())
        case .notDetermined:
            Task { @MainActor [weak self] in
                let wasMicrophoneAccessGranted = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self, !self.wasStoppedByCaller else {
                    completion(false)
                    return
                }
                if wasMicrophoneAccessGranted {
                    completion(self.startAudioEngine())
                } else {
                    print("[MicrophoneSpeechAudioSource] Microphone access was denied.")
                    completion(false)
                }
            }
        case .denied, .restricted:
            print("[MicrophoneSpeechAudioSource] Microphone access is denied; enable it in System Settings → Privacy & Security → Microphone.")
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func stopCapturing() {
        wasStoppedByCaller = true
        isDeliveringAudio = false
        if let runningAudioEngine {
            runningAudioEngine.inputNode.removeTap(onBus: 0)
            runningAudioEngine.stop()
        }
        runningAudioEngine = nil
    }

    private func startAudioEngine() -> Bool {
        guard !wasStoppedByCaller else { return false }

        let audioEngine = AVAudioEngine()
        let microphoneInputNode = audioEngine.inputNode
        let microphoneNativeFormat = microphoneInputNode.outputFormat(forBus: 0)

        // A zero sample rate / channel count means there is no usable input
        // device (e.g. a Mac mini with nothing plugged in).
        guard microphoneNativeFormat.sampleRate > 0, microphoneNativeFormat.channelCount > 0 else {
            print("[MicrophoneSpeechAudioSource] No usable microphone input (format: \(microphoneNativeFormat)).")
            return false
        }
        guard let chunkConverter = PCM16MonoSpeechChunkConverter(microphoneNativeFormat: microphoneNativeFormat) else {
            print("[MicrophoneSpeechAudioSource] Could not build an audio converter from \(microphoneNativeFormat).")
            return false
        }

        // These handlers run on the real-time audio thread. They only hop the
        // finished values over to the main thread; `self` is a main-actor
        // class, so it is safe to carry across.
        let deliverChunkOnMainThread: @Sendable (Data) -> Void = { [weak self] speechChunk in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isDeliveringAudio else { return }
                    self.onAudioChunk?(speechChunk)
                }
            }
        }
        let deliverLevelOnMainThread: @Sendable (Float) -> Void = { [weak self] audioLevel in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isDeliveringAudio else { return }
                    self.onAudioLevel?(audioLevel)
                }
            }
        }

        microphoneInputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: microphoneNativeFormat,
            block: chunkConverter.makeAudioTapBlock(
                onSpeechChunkReady: deliverChunkOnMainThread,
                onAudioLevelMeasured: deliverLevelOnMainThread
            )
        )

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            microphoneInputNode.removeTap(onBus: 0)
            print("[MicrophoneSpeechAudioSource] AVAudioEngine failed to start: \(error)")
            return false
        }

        runningAudioEngine = audioEngine
        isDeliveringAudio = true
        return true
    }
}

/// Runs on the audio thread: resamples whatever the microphone gives us
/// (usually 44.1/48 kHz float, sometimes multi-channel) down to 16 kHz mono
/// PCM16, and cuts it into fixed-size chunks.
///
/// `@unchecked Sendable` is honest here: after init, every mutable property is
/// touched only from the audio tap callback, which Core Audio calls serially.
nonisolated final class PCM16MonoSpeechChunkConverter: @unchecked Sendable {
    static let assemblyAISampleRate: Double = 16_000
    /// 50 ms of 16 kHz mono 16-bit audio. AssemblyAI accepts 50–1000 ms
    /// chunks; the low end keeps end-of-turn detection as snappy as possible.
    static let bytesPerSpeechChunk = Int(assemblyAISampleRate * 0.050) * MemoryLayout<Int16>.size

    private let sampleRateConverter: AVAudioConverter
    private let speechOutputFormat: AVAudioFormat
    private var bytesWaitingToFillAChunk = Data()

    init?(microphoneNativeFormat: AVAudioFormat) {
        guard let speechOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.assemblyAISampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }
        guard let sampleRateConverter = AVAudioConverter(from: microphoneNativeFormat, to: speechOutputFormat) else {
            return nil
        }
        self.speechOutputFormat = speechOutputFormat
        self.sampleRateConverter = sampleRateConverter
    }

    func makeAudioTapBlock(
        onSpeechChunkReady: @escaping @Sendable (Data) -> Void,
        onAudioLevelMeasured: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        return { [self] microphoneBuffer, _ in
            self.convertAndChunk(
                microphoneBuffer: microphoneBuffer,
                onSpeechChunkReady: onSpeechChunkReady,
                onAudioLevelMeasured: onAudioLevelMeasured
            )
        }
    }

    private func convertAndChunk(
        microphoneBuffer: AVAudioPCMBuffer,
        onSpeechChunkReady: @Sendable (Data) -> Void,
        onAudioLevelMeasured: @Sendable (Float) -> Void
    ) {
        let resampleRatio = Self.assemblyAISampleRate / microphoneBuffer.format.sampleRate
        // A little headroom: the resampler can emit a few frames it held back
        // from the previous call.
        let outputFrameCapacity = AVAudioFrameCount(Double(microphoneBuffer.frameLength) * resampleRatio) + 64
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: speechOutputFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        // The converter calls its input block synchronously, inside convert(),
        // on this same thread, so sharing these with it is safe even though the
        // block is typed @Sendable.
        nonisolated(unsafe) var hasHandedOverMicrophoneBuffer = false
        nonisolated(unsafe) let microphoneBufferForConverter = microphoneBuffer
        var conversionError: NSError?
        let conversionStatus = sampleRateConverter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            // Hand over this one buffer, then say "no more for now" (not "end of
            // stream") so the resampler keeps its filter state between taps.
            if hasHandedOverMicrophoneBuffer {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasHandedOverMicrophoneBuffer = true
            inputStatus.pointee = .haveData
            return microphoneBufferForConverter
        }
        guard conversionStatus != .error, conversionError == nil else { return }

        let convertedFrameCount = Int(convertedBuffer.frameLength)
        guard convertedFrameCount > 0, let int16Samples = convertedBuffer.int16ChannelData?[0] else { return }

        onAudioLevelMeasured(Self.normalizedLoudness(of: int16Samples, sampleCount: convertedFrameCount))

        // Int16 in memory on Apple silicon / Intel is already little-endian,
        // which is exactly pcm_s16le.
        bytesWaitingToFillAChunk.append(
            UnsafeBufferPointer(start: int16Samples, count: convertedFrameCount)
        )
        while bytesWaitingToFillAChunk.count >= Self.bytesPerSpeechChunk {
            let speechChunk = bytesWaitingToFillAChunk.prefix(Self.bytesPerSpeechChunk)
            onSpeechChunkReady(Data(speechChunk))
            bytesWaitingToFillAChunk.removeFirst(Self.bytesPerSpeechChunk)
        }
    }

    /// RMS loudness mapped from -50 dBFS…0 dBFS onto 0…1. A log scale matches
    /// how loud speech feels; -50 dB is roughly a quiet room's noise floor.
    private static func normalizedLoudness(of int16Samples: UnsafeMutablePointer<Int16>, sampleCount: Int) -> Float {
        var sumOfSquares: Float = 0
        for sampleIndex in 0..<sampleCount {
            let normalizedSample = Float(int16Samples[sampleIndex]) / Float(Int16.max)
            sumOfSquares += normalizedSample * normalizedSample
        }
        let rootMeanSquare = (sumOfSquares / Float(sampleCount)).squareRoot()
        let decibelsFullScale = 20 * log10(max(rootMeanSquare, 0.000_001))
        let quietestAudibleDecibels: Float = -50
        return min(max((decibelsFullScale - quietestAudibleDecibels) / -quietestAudibleDecibels, 0), 1)
    }
}
