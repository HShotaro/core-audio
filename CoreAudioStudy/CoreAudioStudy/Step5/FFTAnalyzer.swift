import Accelerate

// vDSP を使った FFT 解析
// 時間領域のサンプル列 → 周波数領域のマグニチュードスペクトル
final class FFTAnalyzer {
    let fftSize: Int
    let binCount: Int  // = fftSize / 2（実数FFTの出力は半分）

    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup
    private var window: [Float]       // Hanning ウィンドウ（スペクトルリーク低減）
    private var realBuffer: [Float]
    private var imagBuffer: [Float]

    init(fftSize: Int = 2048) {
        self.fftSize = fftSize
        self.binCount = fftSize / 2
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Hanning ウィンドウ係数を事前計算
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        self.realBuffer = [Float](repeating: 0, count: binCount)
        self.imagBuffer = [Float](repeating: 0, count: binCount)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // サンプル列を受け取り dB マグニチュードスペクトル（binCount 個）を返す
    func analyze(_ samples: [Float]) -> [Float] {
        guard samples.count >= fftSize else {
            return [Float](repeating: -80, count: binCount)
        }

        // Step 1: Hanning ウィンドウを乗算（端部のノイズを抑制）
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var result = [Float](repeating: -80, count: binCount)

        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                // Step 2: 実数配列 → DSPSplitComplex（実部・虚部を分離）
                windowed.withUnsafeBytes { rawBytes in
                    let complexPtr = rawBytes.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(binCount))
                }

                // Step 3: 高速フーリエ変換（Forward FFT）
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // Step 4: 複素数 → マグニチュード（|z| = sqrt(r² + i²)）
                var magnitudes = [Float](repeating: 0, count: binCount)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(binCount))

                // Step 5: 正規化
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(binCount))

                // Step 6: dB 変換 → [-80, 0] にクリップ
                var ref: Float = 1.0
                vDSP_vdbcon(magnitudes, 1, &ref, &result, 1, vDSP_Length(binCount), 0)
                var floor: Float = -80; var ceil: Float = 0
                vDSP_vclip(result, 1, &floor, &ceil, &result, 1, vDSP_Length(binCount))
            }
        }
        return result
    }

    // bin インデックス → 周波数 Hz
    func frequency(for bin: Int, sampleRate: Double) -> Double {
        Double(bin) * sampleRate / Double(fftSize)
    }
}
