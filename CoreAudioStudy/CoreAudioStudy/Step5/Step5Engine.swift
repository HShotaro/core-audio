import AVFoundation
import Accelerate

final class Step5Engine {
    // 再生するシグナルの種類
    enum Signal: String, CaseIterable {
        case single440       = "440 Hz（単音）"
        case chord           = "440 + 880 + 1320 Hz（和音）"
        case iirFiltered     = "和音 + 一次IIR LPF（-20 dB/decade）"
        case biquadFiltered  = "和音 + Biquad LPF（-40 dB/decade）"
    }

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    let fftAnalyzer        = FFTAnalyzer(fftSize: 2048)

    var onSpectrumUpdate: (([Float]) -> Void)?
    private(set) var isRunning  = false
    private(set) var sampleRate: Double = 44100

    // MARK: - セットアップ

    func setup() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
        sampleRate = session.sampleRate

        engine.attach(playerNode)
        // バッファがモノラルのため、接続フォーマットも明示的にモノラルで揃える
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(playerNode, to: engine.mainMixerNode, format: monoFormat)

        // installTap で FFT 解析用にオーディオをキャプチャ
        // Step 3 で学んだ「流れを変えずに観測」するための tap
        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            guard let self,
                  let channelData = buffer.floatChannelData else { return }
            let count = min(Int(buffer.frameLength), self.fftAnalyzer.fftSize)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
            let spectrum = self.fftAnalyzer.analyze(samples)
            DispatchQueue.main.async { self.onSpectrumUpdate?(spectrum) }
        }
        try? engine.start()
    }

    // MARK: - 再生

    func play(_ signal: Signal) {
        let frequencies: [Float] = (signal == .single440) ? [440] : [440, 880, 1320]

        guard let buffer = generateBuffer(
            frequencies: frequencies,
            sampleRate: Float(sampleRate),
            duration: 2.0,
            signal: signal
        ) else { return }

        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
        playerNode.play()
        isRunning = true
    }

    func stop() {
        playerNode.stop()
        isRunning = false
    }

    func dispose() {
        stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - バッファ生成

    private func generateBuffer(
        frequencies: [Float],
        sampleRate: Float,
        duration: Float,
        signal: Signal
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let amplitude = 1.0 / Float(frequencies.count)
        for frame in 0..<Int(frameCount) {
            var sample: Float = 0
            for freq in frequencies {
                sample += amplitude * sin(2.0 * .pi * freq * Float(frame) / sampleRate)
            }
            data[frame] = sample
        }

        switch signal {
        case .iirFiltered:
            applyIIRLowPass(data: data, count: Int(frameCount), cutoff: 800, sampleRate: sampleRate)
        case .biquadFiltered:
            let filter = BiquadLPFilter(cutoff: 800, sampleRate: sampleRate)
            filter.process(data: data, count: Int(frameCount))
        default:
            break
        }
        return buffer
    }

    // 一次 IIR ローパス: y[n] = α * x[n] + (1-α) * y[n-1]
    // ロールオフ: -20 dB/decade
    private func applyIIRLowPass(data: UnsafeMutablePointer<Float>, count: Int, cutoff: Float, sampleRate: Float) {
        let omega = 2.0 * Float.pi * cutoff
        let alpha = omega / (omega + sampleRate)
        var prev: Float = 0
        for i in 0..<count {
            data[i] = alpha * data[i] + (1 - alpha) * prev
            prev = data[i]
        }
    }
}
