import Observation
import Foundation

@Observable
final class Step6ViewModel {
    var currentResult: PitchResult?
    var isRunning = false
    var setupError: String?
    var sampleRate: Double = 0

    private let engine = PitchEngine()
    private var pollingTimer: Timer?

    func setup() {
        engine.onPitchDetected = { [weak self] result in
            self?.currentResult = result
        }
        engine.setup()
        sampleRate = engine.sampleRate
        setupError = engine.setupError
    }

    func start() {
        engine.start()
        isRunning = true
        // メインスレッドで Queue をポーリングして UI を更新
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.engine.pollResults()
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        engine.stop()
        isRunning = false
        currentResult = nil
    }

    func cleanup() {
        stop()
        engine.dispose()
    }
}
