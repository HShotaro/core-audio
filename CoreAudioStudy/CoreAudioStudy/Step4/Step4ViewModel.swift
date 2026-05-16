import Observation

@Observable
final class Step4ViewModel {
    var isRunning = false
    var frequency: Double = 440
    var volume: Float = 0.5
    var sampleRate: Double = 0
    var errorMessage: String?

    private let engine = SafeRenderEngine()

    func setup() {
        engine.setup()
        sampleRate = engine.sampleRate
        errorMessage = engine.setupError
    }

    func togglePlayback() {
        engine.isRunning ? engine.stop() : engine.start()
        isRunning = engine.isRunning
    }

    // UIスレッドから LockFreeQueue 経由でコマンドを送る
    func updateFrequency(_ hz: Double) {
        frequency = hz
        engine.sendCommand(.setFrequency(hz))
    }

    func updateVolume(_ vol: Float) {
        volume = vol
        engine.sendCommand(.setVolume(vol))
    }

    func cleanup() {
        engine.dispose()
        isRunning = false
    }
}
