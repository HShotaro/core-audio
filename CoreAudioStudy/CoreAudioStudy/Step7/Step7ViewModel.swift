import Observation
import Foundation

@Observable
final class Step7ViewModel {
    var noteScores: [NoteScore] = []
    var totalScore: Double = 0
    var currentExpectedNote: NoteEvent?
    var currentDetectedNote: String = "--"
    var progress: Double = 0
    var isFinished = false
    var converterResult: AudioConverterDemo.ConversionResult?
    var isRunning = false
    var setupError: String?

    // オクターブシフト（-2〜+2）
    // 0 = 元のオクターブ3、-1 = オクターブ2（低め）、+1 = オクターブ4（高め）
    var octaveShift: Int = 0

    // オクターブシフトを適用したメロディ
    var transposedMelody: [NoteEvent] {
        twinkleMelody.map { $0.transposed(byOctaves: octaveShift) }
    }

    private let engine = KaraokeEngine()
    private var scoreEngine = ScoreEngine()
    private var pollingTimer: Timer?
    private var latestPitchResult: PitchResult?

    // MARK: - ライフサイクル

    func setup() {
        engine.onPitchDetected = { [weak self] result in
            self?.currentDetectedNote = result.noteName
            self?.latestPitchResult = result
        }
        engine.setup()
        setupError = engine.setupError
    }

    func startSinging() {
        guard !isRunning else { return }
        // 現在のオクターブシフトを適用したメロディで ScoreEngine を初期化
        scoreEngine = ScoreEngine(melody: transposedMelody)
        engine.start()
        scoreEngine.start()
        isRunning = true
        isFinished = false

        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        engine.stop()
        isRunning = false
    }

    func reset() {
        stop()
        scoreEngine.reset()
        noteScores = []
        totalScore = 0
        currentExpectedNote = nil
        currentDetectedNote = "--"
        progress = 0
        isFinished = false
        latestPitchResult = nil
    }

    func cleanup() {
        stop()
        engine.dispose()
    }

    func runConverterDemo() {
        let dummySamples = (0..<1024).map { i in
            Float(sin(2.0 * .pi * 440.0 * Double(i) / 48000.0))
        }
        converterResult = AudioConverterDemo.convert(
            samples: dummySamples,
            inputSampleRate: engine.sampleRate > 0 ? engine.sampleRate : 48000
        )
    }

    // MARK: - Private

    private func poll() {
        engine.pollResults()

        let prevNote = currentExpectedNote
        currentExpectedNote = scoreEngine.currentExpectedNote()

        if currentExpectedNote?.noteName != prevNote?.noteName {
            engine.setBGMFrequency(currentExpectedNote?.frequency ?? 0)
        }

        if let result = latestPitchResult {
            scoreEngine.evaluate(frequency: result.frequency, confidence: result.confidence)
        }

        noteScores = scoreEngine.noteScores
        totalScore = scoreEngine.totalScore
        progress   = scoreEngine.progress

        if scoreEngine.isFinished && !isFinished {
            isFinished = true
            stop()
        }
    }
}
