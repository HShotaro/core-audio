import Accelerate

struct PitchResult {
    let frequency: Double  // 検出した周波数 (Hz)
    let noteName: String   // 音名 + オクターブ (例: "A4", "C#3")
    let cents: Double      // 基準音からのズレ (-50〜+50 cents, 0 = 完璧)
    let confidence: Float  // 検出の確からしさ (0〜1)
}

// FFT + HPS（Harmonic Product Spectrum）によるピッチ検出
// すべて静的メソッドで実装（インスタンスの状態を持たない純粋なDSP処理）
enum PitchDetector {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    // MARK: - メインエントリーポイント

    static func detect(samples: [Float], sampleRate: Double) -> PitchResult? {
        let fftSize = samples.count
        guard fftSize >= 512 else { return nil }

        // Step 1: FFT でマグニチュードスペクトルを計算
        let spectrum = computeSpectrum(samples, fftSize: fftSize)

        // Step 2: HPS で基本周波数の bin を特定
        let peakBin = hps(spectrum: spectrum, harmonics: 3)

        // Step 3: bin → 周波数 (Hz)
        let binWidth = sampleRate / Double(fftSize)
        let frequency = Double(peakBin) * binWidth

        // 人声の範囲外は無効（60 Hz〜1200 Hz）
        guard frequency > 60 && frequency < 1200 else { return nil }

        // Step 4: 信頼度（ピークが全体の最大値に対してどれくらい強いか）
        let maxMag = spectrum.max() ?? 1
        let confidence = maxMag > 0 ? spectrum[peakBin] / maxMag : 0
        guard confidence > 0.05 else { return nil }

        // Step 5: Hz → 音名 + セント偏差
        let (name, cents) = noteAndCents(from: frequency)

        return PitchResult(frequency: frequency, noteName: name, cents: cents, confidence: confidence)
    }

    // MARK: - FFT マグニチュードスペクトル

    static func computeSpectrum(_ samples: [Float], fftSize: Int) -> [Float] {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        // Hanning ウィンドウ（スペクトルリーク低減）
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { rPtr in
            imag.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        return magnitudes
    }

    // MARK: - HPS (Harmonic Product Spectrum)

    // スペクトルと、それを 2・3 倍に間引いたコピーの積を計算する。
    // 基本周波数の倍音が重なることで基本周波数のビンが強調される。
    //
    // 例: 基本周波数 f0 の場合
    //   元スペクトル: spike at f0, 2f0, 3f0
    //   ÷2 圧縮:     spike at f0 (←2f0が移動), 1.5f0 (←3f0が移動)
    //   ÷3 圧縮:     spike at f0 (←3f0が移動)
    //   積: f0 のスパイクのみが3回掛け合わされて強調される
    static func hps(spectrum: [Float], harmonics: Int) -> Int {
        // harmonics 倍の周波数まで使うため、有効な bin 数を制限
        let validCount = spectrum.count / harmonics
        var product = Array(spectrum.prefix(validCount))

        for h in 2...harmonics {
            for i in 0..<validCount {
                let srcIndex = i * h
                if srcIndex < spectrum.count {
                    product[i] *= spectrum[srcIndex]
                } else {
                    product[i] = 0
                }
            }
        }

        // DC 成分と極低周波を除いてピーク探索（人声範囲: 60〜1200 Hz）
        let minBin = 4
        let maxBin = validCount - 1
        var maxVal: Float = 0
        var peakBin = minBin

        for i in minBin...maxBin {
            if product[i] > maxVal {
                maxVal = product[i]
                peakBin = i
            }
        }
        return peakBin
    }

    // MARK: - Hz → 音名 + セント偏差

    // MIDI ノート番号を経由して音名とセント偏差を計算する。
    // セント (cent) = 音程の単位。1 半音 = 100 cents。
    // A4 = 440 Hz = MIDI ノート 69 を基準とする。
    static func noteAndCents(from frequency: Double) -> (name: String, cents: Double) {
        // MIDI ノート番号（小数点以下 = セント偏差）
        let midiNote = 12.0 * log2(frequency / 440.0) + 69.0
        let roundedMidi = Int(round(midiNote))

        let noteIndex = ((roundedMidi % 12) + 12) % 12
        let octave    = roundedMidi / 12 - 1

        // 最近傍音の基準周波数
        let refFreq = 440.0 * pow(2.0, (Double(roundedMidi) - 69.0) / 12.0)
        let cents   = 1200.0 * log2(frequency / refFreq)

        return ("\(noteNames[noteIndex])\(octave)", cents)
    }
}
