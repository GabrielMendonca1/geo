import AVFoundation
import Foundation

struct FeedbackToneLayer {
    let delay: Double
    let duration: Double
    let startFrequency: Double
    let endFrequency: Double
    let amplitude: Double
    let decay: Double
    let overtone: Double
}

enum FeedbackVoice {
    static let sampleRate: Double = 44100
    static let attackSeconds: Double = 0.004
    static let releaseSeconds: Double = 0.008

    static func layers(for cue: FeedbackCue) -> [FeedbackToneLayer] {
        switch cue {
        case .sectorChanged:
            return [
                FeedbackToneLayer(delay: 0, duration: 0.055, startFrequency: 892, endFrequency: 928,
                                  amplitude: 1.0, decay: 34, overtone: 0.12),
            ]
        case .selection:
            return [
                FeedbackToneLayer(delay: 0, duration: 0.042, startFrequency: 1324, endFrequency: 1324,
                                  amplitude: 1.0, decay: 52, overtone: 0.2),
            ]
        case .start:
            return [
                FeedbackToneLayer(delay: 0, duration: 0.07, startFrequency: 521, endFrequency: 538,
                                  amplitude: 0.85, decay: 26, overtone: 0.1),
                FeedbackToneLayer(delay: 0.062, duration: 0.1, startFrequency: 784, endFrequency: 790,
                                  amplitude: 0.8, decay: 21, overtone: 0.08),
            ]
        case .completed:
            return [
                FeedbackToneLayer(delay: 0, duration: 0.075, startFrequency: 659, endFrequency: 659,
                                  amplitude: 0.75, decay: 27, overtone: 0.09),
                FeedbackToneLayer(delay: 0.066, duration: 0.085, startFrequency: 988, endFrequency: 988,
                                  amplitude: 0.7, decay: 24, overtone: 0.07),
                FeedbackToneLayer(delay: 0.134, duration: 0.13, startFrequency: 1319, endFrequency: 1311,
                                  amplitude: 0.62, decay: 19, overtone: 0.05),
            ]
        case .cancelled:
            return [
                FeedbackToneLayer(delay: 0, duration: 0.075, startFrequency: 712, endFrequency: 648,
                                  amplitude: 0.8, decay: 25, overtone: 0.08),
                FeedbackToneLayer(delay: 0.062, duration: 0.12, startFrequency: 468, endFrequency: 432,
                                  amplitude: 0.72, decay: 20, overtone: 0.06),
            ]
        case .error:
            return [
                FeedbackToneLayer(delay: 0, duration: 0.09, startFrequency: 311, endFrequency: 303,
                                  amplitude: 0.95, decay: 22, overtone: 0.32),
                FeedbackToneLayer(delay: 0.125, duration: 0.14, startFrequency: 294, endFrequency: 286,
                                  amplitude: 0.85, decay: 18, overtone: 0.28),
            ]
        }
    }

    static func totalDuration(for cue: FeedbackCue) -> Double {
        layers(for: cue).reduce(0) { max($0, $1.delay + $1.duration) } + releaseSeconds
    }

    static func samples(for cue: FeedbackCue, sampleRate: Double = FeedbackVoice.sampleRate) -> [Float] {
        let rate = sampleRate > 0 ? sampleRate : FeedbackVoice.sampleRate
        let frameCount = max(1, Int((totalDuration(for: cue) * rate).rounded(.up)))
        var mix = [Double](repeating: 0, count: frameCount)

        for layer in layers(for: cue) {
            let offset = Int(layer.delay * rate)
            let span = max(1, Int(layer.duration * rate))
            var phase = 0.0
            for index in 0..<span {
                let target = offset + index
                if target >= frameCount { break }
                let position = Double(index) / rate
                let progress = Double(index) / Double(span)
                let frequency = layer.startFrequency + (layer.endFrequency - layer.startFrequency) * progress
                phase += 2 * Double.pi * frequency / rate
                let fundamental = sin(phase)
                let harmonic = sin(2 * phase) * layer.overtone
                let envelope = amplitudeEnvelope(position: position, duration: layer.duration, decay: layer.decay)
                mix[target] += (fundamental + harmonic) * envelope * layer.amplitude
            }
        }

        var output = [Float](repeating: 0, count: frameCount)
        let tail = max(1, Int(releaseSeconds * rate))
        for index in 0..<frameCount {
            var value = tanh(mix[index] * 0.9)
            let remaining = frameCount - index
            if remaining < tail {
                value *= Double(remaining) / Double(tail)
            }
            output[index] = Float(value)
        }
        return output
    }

    static func amplitudeEnvelope(position: Double, duration: Double, decay: Double) -> Double {
        guard position >= 0, duration > 0 else { return 0 }
        let attack = min(attackSeconds, duration * 0.4)
        var envelope = exp(-position * decay)
        if position < attack, attack > 0 {
            envelope *= 0.5 - 0.5 * cos(Double.pi * position / attack)
        }
        let fadeStart = duration - min(releaseSeconds, duration * 0.5)
        if position > fadeStart {
            let span = max(0.0001, duration - fadeStart)
            envelope *= max(0, (duration - position) / span)
        }
        return envelope
    }

    static func wav(for cue: FeedbackCue,
                    sampleRate: Double = FeedbackVoice.sampleRate,
                    channels: Int = 1) -> Data {
        let rate = sampleRate > 0 ? sampleRate : FeedbackVoice.sampleRate
        return wav(samples: samples(for: cue, sampleRate: rate), sampleRate: rate, channels: channels)
    }

    static func wav(samples: [Float], sampleRate: Double, channels: Int = 1) -> Data {
        let rate = sampleRate > 0 ? sampleRate : FeedbackVoice.sampleRate
        let channelCount = max(1, min(2, channels))
        let bitsPerSample = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = Int(rate.rounded()) * blockAlign
        let dataBytes = samples.count * blockAlign

        var data = Data(capacity: 44 + dataBytes)
        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: Int) {
            let clamped = UInt32(truncatingIfNeeded: value)
            data.append(contentsOf: [UInt8(clamped & 0xFF),
                                     UInt8((clamped >> 8) & 0xFF),
                                     UInt8((clamped >> 16) & 0xFF),
                                     UInt8((clamped >> 24) & 0xFF)])
        }
        func appendUInt16(_ value: Int) {
            let clamped = UInt16(truncatingIfNeeded: value)
            data.append(contentsOf: [UInt8(clamped & 0xFF), UInt8((clamped >> 8) & 0xFF)])
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataBytes)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(channelCount)
        appendUInt32(Int(rate.rounded()))
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(dataBytes)

        for sample in samples {
            let bounded = max(-1, min(1, Double(sample)))
            let scaled = Int16((bounded * 32767).rounded())
            for _ in 0..<channelCount {
                appendUInt16(Int(scaled))
            }
        }
        return data
    }

    static func buffer(for cue: FeedbackCue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = samples(for: cue, sampleRate: format.sampleRate)
        guard !frames.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            for index in 0..<frames.count {
                pointer[index] = frames[index]
            }
        }
        return buffer
    }
}
