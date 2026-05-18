import AVFoundation
import AudioToolbox

// MARK: - PitchContext（コールバックと PitchEngine の共有状態）

final class PitchContext {
    var vpio: AudioUnit?

    // コールバック内で malloc しないための事前確保バッファ
    let maxFrames = 4096
    let inputBuffer: UnsafeMutablePointer<Float32>

    // サンプル蓄積バッファ（FFT サイズ分溜まったらピッチ検出を実行）
    let fftSize = 4096
    var accumulator: [Float]
    var writeIndex: Int = 0
    var samplesAccumulated: Int = 0

    // Step 4 の SPSC Queue でオーディオスレッド → UI スレッドに結果を渡す
    let resultQueue = LockFreeQueue<PitchResult>()

    var sampleRate: Double = 44100

    init() {
        inputBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
        inputBuffer.initialize(repeating: 0, count: maxFrames)
        accumulator = [Float](repeating: 0, count: fftSize)
    }

    deinit { inputBuffer.deallocate() }
}

// MARK: - 入力コールバック（オーディオスレッドで実行）

// Step 3 の RenderCallback との違い:
//   RenderCallback  = AU が「データをくれ」と要求 → アプリが書き込む
//   InputCallback   = AU が「データが届いた」と通知 → アプリが AudioUnitRender で取り出す
private let micInputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let ctx = Unmanaged<PitchContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let vpio = ctx.vpio else { return noErr }

    // AudioBufferList をスタック上に構築（malloc なし）
    var buffer = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize:   inNumberFrames * UInt32(MemoryLayout<Float32>.size),
        mData:           ctx.inputBuffer
    )
    var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)

    // VPIO Bus 1 からマイクデータをプル（InputCallback では ioData が nil のため自前で取り出す）
    let status = AudioUnitRender(vpio, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return noErr }

    // サンプルを蓄積バッファに追記
    let frameCount = Int(inNumberFrames)
    for i in 0..<frameCount {
        ctx.accumulator[ctx.writeIndex] = ctx.inputBuffer[i]
        ctx.writeIndex = (ctx.writeIndex + 1) % ctx.fftSize
    }
    ctx.samplesAccumulated = min(ctx.samplesAccumulated + frameCount, ctx.fftSize)

    // fftSize 分揃ったらピッチ検出を実行してバッファをリセット
    guard ctx.samplesAccumulated >= ctx.fftSize else { return noErr }

    // 循環バッファ → 線形配列に展開
    // 注: Array 生成は malloc を伴うため本来はリアルタイムスレッドで禁止。
    //     プロダクション環境では事前確保バッファ + DispatchQueue への dispatch で対応する。
    var ordered = [Float](repeating: 0, count: ctx.fftSize)
    for i in 0..<ctx.fftSize {
        ordered[i] = ctx.accumulator[(ctx.writeIndex + i) % ctx.fftSize]
    }

    if let result = PitchDetector.detect(samples: ordered, sampleRate: ctx.sampleRate) {
        _ = ctx.resultQueue.enqueue(result)
    }

    // バッファをリセット（次の fftSize サンプルが揃うまで再検出しない）
    ctx.samplesAccumulated = 0

    return noErr
}

// MARK: - PitchEngine

final class PitchEngine {
    private var vpio: AudioUnit?
    private let context = PitchContext()
    private(set) var isRunning = false
    private(set) var setupError: String?
    private(set) var sampleRate: Double = 0

    var onPitchDetected: ((PitchResult) -> Void)?

    // MARK: - セットアップ

    func setup() {
        setupError = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record)
            try session.setActive(true)
        } catch {
            setupError = "AVAudioSession: \(error.localizedDescription)"
            return
        }
        sampleRate = session.sampleRate
        context.sampleRate = sampleRate

        guard createVPIO()       else { setupError = "VPIO: 生成失敗"; return }
        guard configureIO()      else { setupError = "IO: 設定失敗"; return }
        guard setStreamFormat()  else { setupError = "StreamFormat: 設定失敗"; return }
        guard setInputCallback() else { setupError = "InputCallback: 設定失敗"; return }

        guard AudioUnitInitialize(vpio!) == noErr else {
            setupError = "AudioUnitInitialize: 失敗"
            return
        }
        // コールバック内の AudioUnitRender に VPIO ポインタを渡すため context に保持
        context.vpio = vpio
    }

    func start() {
        guard let au = vpio else { return }
        AudioOutputUnitStart(au)
        isRunning = true
    }

    func stop() {
        guard let au = vpio else { return }
        AudioOutputUnitStop(au)
        isRunning = false
    }

    func dispose() {
        stop()
        if let au = vpio {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            vpio = nil
            context.vpio = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // Queue から結果を取り出して onPitchDetected に渡す（メインスレッドから呼ぶ）
    func pollResults() {
        while let result = context.resultQueue.dequeue() {
            onPitchDetected?(result)
        }
    }

    // MARK: - C API セットアップ

    private func createVPIO() -> Bool {
        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return false }
        return AudioComponentInstanceNew(comp, &vpio) == noErr
    }

    private func configureIO() -> Bool {
        guard let au = vpio else { return false }
        var enable:  UInt32 = 1
        var disable: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        // Bus 1 (Input) を有効化
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1, &enable, size) == noErr else { return false }
        // Bus 0 (Output) を無効化（マイク音がスピーカーから出ないように）
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0, &disable, size) == noErr else { return false }
        return true
    }

    private func setStreamFormat() -> Bool {
        guard let au = vpio else { return false }
        // Bus 1, Output Scope = マイクから出てくるデータのフォーマット（Step 1 の Scope 復習）
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: 1,
            mBitsPerChannel:   32,
            mReserved:         0
        )
        return AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1,
            &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr
    }

    private func setInputCallback() -> Bool {
        guard let au = vpio else { return false }
        var cb = AURenderCallbackStruct(
            inputProc:       micInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        return AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr
    }
}
