import Accelerate

// vDSP_biquad を使った二次バターワースローパスフィルター
// ロールオフ: -40 dB/decade（一次IIRの2倍の急峻さ）
//
// 伝達関数:
// H(z) = (b0 + b1*z^{-1} + b2*z^{-2}) / (1 + a1*z^{-1} + a2*z^{-2})
//
// バターワース係数 (Q = 1/√2):
// b0 = (1 - cos ω) / 2
// b1 =  1 - cos ω
// b2 = (1 - cos ω) / 2
// a1 = -2 * cos ω       ← a0 で正規化済み
// a2 =  1 - sin ω / (2Q)  ← a0 で正規化済み

final class BiquadLPFilter {
    private let setup: vDSP_biquad_Setup
    // delay: vDSP_biquad が内部状態を保持するバッファ（サイズ = 2 * (sections + 1)）
    // Float版（vDSP_biquad）は Float、Double版（vDSP_biquadD）は Double
    private var delay: [Float]

    init(cutoff: Float, sampleRate: Float) {
        let omega    = 2.0 * Float.pi * cutoff / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)
        let q        = Float(1.0 / sqrt(2.0)) // バターワース特性
        let alpha    = sinOmega / (2.0 * q)

        let b0 = (1.0 - cosOmega) / 2.0
        let b1 =  1.0 - cosOmega
        let b2 = (1.0 - cosOmega) / 2.0
        let a0 =  1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 =  1.0 - alpha

        // vDSP_biquad の係数順: [b0, b1, b2, a1, a2]（a0 で正規化済み）
        let coefficients: [Double] = [
            Double(b0 / a0),
            Double(b1 / a0),
            Double(b2 / a0),
            Double(a1 / a0),
            Double(a2 / a0)
        ]
        self.setup = vDSP_biquad_CreateSetup(coefficients, 1)! // 1 section = 二次フィルター
        self.delay = [Float](repeating: 0, count: 4)           // 2 * (1 + 1) = 4
    }

    deinit { vDSP_biquad_DestroySetup(setup) }

    // data を in-place でフィルタリングする
    func process(data: UnsafeMutablePointer<Float>, count: Int) {
        var output = [Float](repeating: 0, count: count)
        vDSP_biquad(setup, &delay, data, 1, &output, 1, vDSP_Length(count))
        output.withUnsafeBufferPointer { src in
            data.update(from: src.baseAddress!, count: count)
        }
    }
}
