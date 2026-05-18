import AudioToolbox

// AudioConverter C API のデモ
// ユースケース: VPIO が出力する Float32 / 48000 Hz を
//              ファイル保存や通信向けの Int16 / 44100 Hz に変換する
enum AudioConverterDemo {

    struct ConversionResult {
        let inputFormat:  String  // 変換前フォーマットの説明
        let outputFormat: String  // 変換後フォーマットの説明
        let inputSamples:  Int
        let outputSamples: Int
        let convertedData: [Int16]
    }

    // Float32 @ inputSampleRate (mono) → Int16 @ 44100 Hz (mono) に変換
    static func convert(
        samples: [Float],
        inputSampleRate: Double
    ) -> ConversionResult? {
        // Step 1: 入力 ASBD（VPIO が出力する形式）
        var inputASBD = AudioStreamBasicDescription(
            mSampleRate:       inputSampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: 1,
            mBitsPerChannel:   32,
            mReserved:         0
        )

        // Step 2: 出力 ASBD（ファイル保存・通信向けの形式）
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate:       44100,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   2,
            mFramesPerPacket:  1,
            mBytesPerFrame:    2,
            mChannelsPerFrame: 1,
            mBitsPerChannel:   16,
            mReserved:         0
        )

        // Step 3: AudioConverter を生成
        // 入出力フォーマットが異なる場合、内部でリサンプリングが行われる
        var converter: AudioConverterRef?
        guard AudioConverterNew(&inputASBD, &outputASBD, &converter) == noErr,
              let converter else { return nil }
        defer { AudioConverterDispose(converter) }

        // Step 4: 出力バッファのサイズを計算（サンプルレート比から）
        let outputCount = Int(Double(samples.count) * 44100.0 / inputSampleRate)
        var output = [Int16](repeating: 0, count: outputCount)

        let inputByteSize  = UInt32(samples.count * MemoryLayout<Float>.size)
        var outputByteSize = UInt32(outputCount   * MemoryLayout<Int16>.size)

        // Step 5: 変換実行
        let status: OSStatus = samples.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                guard let inBase = inPtr.baseAddress,
                      let outBase = outPtr.baseAddress else {
                    return kAudio_ParamError
                }
                return AudioConverterConvertBuffer(
                    converter,
                    inputByteSize,
                    inBase,
                    &outputByteSize,
                    outBase
                )
            }
        }
        guard status == noErr else { return nil }

        return ConversionResult(
            inputFormat:   "Float32 / \(Int(inputSampleRate)) Hz / mono",
            outputFormat:  "Int16   / 44100 Hz / mono",
            inputSamples:  samples.count,
            outputSamples: outputCount,
            convertedData: output
        )
    }
}
