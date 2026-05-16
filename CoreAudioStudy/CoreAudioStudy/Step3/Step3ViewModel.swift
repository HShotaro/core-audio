import Observation

@Observable
final class Step3ViewModel {
    var isRunning = false
    var frequency: Double = 440
    var sampleRate: Double = 0
    var errorMessage: String?

    private let engine = RenderCallbackEngine()

    func setup() {
        engine.setup()
        sampleRate = engine.sampleRate
        errorMessage = engine.setupError
    }

    func togglePlayback() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.start()
        }
        isRunning = engine.isRunning
    }

    func updateFrequency(_ hz: Double) {
        frequency = hz
        engine.frequency = hz
    }

    func cleanup() {
        engine.dispose()
        isRunning = false
    }
}
