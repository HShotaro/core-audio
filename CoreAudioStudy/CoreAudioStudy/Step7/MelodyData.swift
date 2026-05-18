import Foundation

// 1音符のデータ
struct NoteEvent {
    let noteName: String   // 例: "C4", "A4"
    let frequency: Double  // 基準周波数 (Hz)
    let startBeat: Double  // 開始拍（曲頭から）
    let durationBeats: Double // 長さ（拍数）

    static let secondsPerBeat: Double = 0.8  // 75 BPM

    var startTime: Double  { startBeat     * Self.secondsPerBeat }
    var endTime:   Double  { (startBeat + durationBeats) * Self.secondsPerBeat }

    // オクターブを n 段階ずらした NoteEvent を返す
    // frequency × 2^n、音名の末尾の数字を ±n する
    func transposed(byOctaves n: Int) -> NoteEvent {
        let newFrequency = frequency * pow(2.0, Double(n))
        let newNoteName  = shiftOctaveInName(noteName, by: n)
        return NoteEvent(
            noteName: newNoteName,
            frequency: newFrequency,
            startBeat: startBeat,
            durationBeats: durationBeats
        )
    }

    private func shiftOctaveInName(_ name: String, by n: Int) -> String {
        // 末尾の数字（オクターブ番号）を取り出して加算する
        // 例: "C#3" → base="C#", octave=3 → "C#4"（n=+1のとき）
        guard let last = name.last, let octave = Int(String(last)) else { return name }
        let base      = String(name.dropLast())
        let newOctave = octave + n
        return "\(base)\(newOctave)"
    }
}

// きらきら星（C major）の前半 — オクターブ3（低めの声向け）
// ド ド ソ ソ ラ ラ ソ ー | ファ ファ ミ ミ レ レ ド ー
let twinkleMelody: [NoteEvent] = [
    NoteEvent(noteName: "C3", frequency: 130.81, startBeat:  0, durationBeats: 1),
    NoteEvent(noteName: "C3", frequency: 130.81, startBeat:  1, durationBeats: 1),
    NoteEvent(noteName: "G3", frequency: 196.00, startBeat:  2, durationBeats: 1),
    NoteEvent(noteName: "G3", frequency: 196.00, startBeat:  3, durationBeats: 1),
    NoteEvent(noteName: "A3", frequency: 220.00, startBeat:  4, durationBeats: 1),
    NoteEvent(noteName: "A3", frequency: 220.00, startBeat:  5, durationBeats: 1),
    NoteEvent(noteName: "G3", frequency: 196.00, startBeat:  6, durationBeats: 2),
    NoteEvent(noteName: "F3", frequency: 174.61, startBeat:  8, durationBeats: 1),
    NoteEvent(noteName: "F3", frequency: 174.61, startBeat:  9, durationBeats: 1),
    NoteEvent(noteName: "E3", frequency: 164.81, startBeat: 10, durationBeats: 1),
    NoteEvent(noteName: "E3", frequency: 164.81, startBeat: 11, durationBeats: 1),
    NoteEvent(noteName: "D3", frequency: 146.83, startBeat: 12, durationBeats: 1),
    NoteEvent(noteName: "D3", frequency: 146.83, startBeat: 13, durationBeats: 1),
    NoteEvent(noteName: "C3", frequency: 130.81, startBeat: 14, durationBeats: 2),
]
