import Foundation

// 1音符分の採点結果
struct NoteScore {
    let expected: NoteEvent    // 期待されたノート
    let detectedHz: Double     // 検出した周波数
    let centsError: Double     // 基準音からのズレ（cents）
    let score: Double          // 0〜100 点
}

final class ScoreEngine {
    let melody: [NoteEvent]
    private(set) var noteScores: [NoteScore] = []
    private(set) var totalScore: Double = 0
    private var startTime: Date?

    init(melody: [NoteEvent] = twinkleMelody) {
        self.melody = melody
    }

    // MARK: - 制御

    func start() {
        startTime = Date()
        noteScores = []
        totalScore = 0
    }

    func reset() {
        startTime = nil
        noteScores = []
        totalScore = 0
    }

    // MARK: - 現在のノート

    func currentExpectedNote() -> NoteEvent? {
        guard let start = startTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        return melody.first { $0.startTime <= elapsed && elapsed < $0.endTime }
    }

    var elapsedTime: Double {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var isFinished: Bool {
        guard let last = melody.last else { return false }
        return elapsedTime >= last.endTime
    }

    var progress: Double {
        guard let last = melody.last, last.endTime > 0 else { return 0 }
        return min(1.0, elapsedTime / last.endTime)
    }

    // MARK: - 採点

    // PitchResult を受け取り現在の期待ノートと比較してスコアを算出
    @discardableResult
    func evaluate(frequency: Double, confidence: Float) -> NoteScore? {
        guard confidence > 0.1,
              let expected = currentExpectedNote() else { return nil }

        // 検出周波数と基準周波数のセント差
        let centsError = abs(1200.0 * log2(frequency / expected.frequency))
        let score = pitchScore(centsError: centsError)

        let noteScore = NoteScore(
            expected: expected,
            detectedHz: frequency,
            centsError: centsError,
            score: score
        )

        // 同じノートに対するスコアは最高値で更新
        if let idx = noteScores.firstIndex(where: {
            $0.expected.noteName == expected.noteName &&
            $0.expected.startBeat == expected.startBeat
        }) {
            if score > noteScores[idx].score {
                noteScores[idx] = noteScore
            }
        } else {
            noteScores.append(noteScore)
        }

        // 総合スコア = 採点済みノートの平均（未採点ノートは 0 点換算しない）
        totalScore = noteScores.map(\.score).reduce(0, +) / Double(noteScores.count)

        return noteScore
    }

    // MARK: - スコア計算式

    // セント誤差 → 点数
    // |cents| < 25  : 100 点（ほぼ正確）
    // |cents| 25-75 : 100→0 点に線形減少
    // |cents| >= 75 : 0 点
    private func pitchScore(centsError: Double) -> Double {
        if centsError < 25  { return 100 }
        if centsError < 75  { return max(0, 100 - (centsError - 25) * 2) }
        return 0
    }
}
