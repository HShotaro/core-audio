import Observation
import Foundation

@Observable
final class Step5ViewModel {
    var spectrum: [Float] = []
    var sampleRate: Double = 0
    var isRunning = false
    var currentSignal: Step5Engine.Signal = .single440

    private let engine = Step5Engine()

    // スペクトル表示に使う bin の上限（〜5kHz まで表示）
    var displayBinCount: Int {
        guard sampleRate > 0 else { return 0 }
        let maxFreq: Double = 5000
        return min(Int(maxFreq / (sampleRate / Double(engine.fftAnalyzer.fftSize))), engine.fftAnalyzer.binCount)
    }

    func setup() {
        engine.onSpectrumUpdate = { [weak self] spectrum in
            self?.spectrum = spectrum
        }
        engine.setup()
        sampleRate = engine.sampleRate
    }

    func play(_ signal: Step5Engine.Signal) {
        currentSignal = signal
        engine.play(signal)
        isRunning = true
    }

    func stop() {
        engine.stop()
        isRunning = false
    }

    func cleanup() {
        engine.dispose()
    }

    func frequencyLabel(for bin: Int) -> String {
        let freq = engine.fftAnalyzer.frequency(for: bin, sampleRate: sampleRate)
        return freq >= 1000 ? String(format: "%.1fk", freq / 1000) : "\(Int(freq))"
    }
}
