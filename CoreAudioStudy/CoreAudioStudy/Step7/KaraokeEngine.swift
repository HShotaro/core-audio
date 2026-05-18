import AVFoundation
import AudioToolbox

// MARK: - KaraokeContext

final class KaraokeContext {
    var vpio: AudioUnit?

    // --- 出力（BGM）---
    var bgmFrequency: Double = 0   // 0 = 無音
    var bgmPhase: Double = 0
    let bgmVolume: Float = 0.2     // AEC が機能するよう適度な音量
    let bgmCommandQueue = LockFreeQueue<Double>()  // UI→オーディオスレッドへ周波数更新

    // --- 入力（マイク）---
    let maxFrames = 4096
    let inputBuffer: UnsafeMutablePointer<Float32>
    let fftSize = 4096
    var accumulator: [Float]
    var writeIndex: Int = 0
    var samplesAccumulated: Int = 0
    let pitchResultQueue = LockFreeQueue<PitchResult>()

    var sampleRate: Double = 44100

    init() {
        inputBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
        inputBuffer.initialize(repeating: 0, count: maxFrames)
        accumulator = [Float](repeating: 0, count: fftSize)
    }

    deinit { inputBuffer.deallocate() }
}

// MARK: - BGM レンダーコールバック（Bus 0 Output）

// VPIO の Bus 0 にサイン波を書き込む = BGM としてスピーカーから鳴らす
// VPIO の AEC が この出力を参照信号として Bus 1 Input から自動除去する
private let bgmRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<KaraokeContext>.fromOpaque(inRefCon).takeUnretainedValue()

    // コールバック冒頭で周波数コマンドを処理（Step 4 のパターン）
    while let newFreq = ctx.bgmCommandQueue.dequeue() {
        ctx.bgmFrequency = newFreq
        if newFreq == 0 { ctx.bgmPhase = 0 }  // 無音になるときは位相をリセット
    }

    let freq      = ctx.bgmFrequency
    let phaseInc  = freq > 0 ? 2.0 * Double.pi * freq / ctx.sampleRate : 0
    let volume    = ctx.bgmVolume

    let ablPointer = UnsafeMutableAudioBufferListPointer(ioData)
    for buffer in ablPointer {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float32.self)
        for frame in 0..<Int(inNumberFrames) {
            samples[frame] = freq > 0 ? Float32(sin(ctx.bgmPhase)) * volume : 0
            ctx.bgmPhase += phaseInc
        }
    }
    if freq > 0 {
        ctx.bgmPhase = ctx.bgmPhase.truncatingRemainder(dividingBy: 2.0 * Double.pi)
    }
    return noErr
}

// MARK: - マイク入力コールバック（Bus 1 Input）

// AEC が BGM 成分を除去した後のクリーンな声だけが届く
private let micInputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let ctx = Unmanaged<KaraokeContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let vpio = ctx.vpio else { return noErr }

    var buffer = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize:   inNumberFrames * UInt32(MemoryLayout<Float32>.size),
        mData:           ctx.inputBuffer
    )
    var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
    let status = AudioUnitRender(vpio, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return noErr }

    let frameCount = Int(inNumberFrames)
    for i in 0..<frameCount {
        ctx.accumulator[ctx.writeIndex] = ctx.inputBuffer[i]
        ctx.writeIndex = (ctx.writeIndex + 1) % ctx.fftSize
    }
    ctx.samplesAccumulated = min(ctx.samplesAccumulated + frameCount, ctx.fftSize)
    guard ctx.samplesAccumulated >= ctx.fftSize else { return noErr }

    var ordered = [Float](repeating: 0, count: ctx.fftSize)
    for i in 0..<ctx.fftSize {
        ordered[i] = ctx.accumulator[(ctx.writeIndex + i) % ctx.fftSize]
    }
    if let result = PitchDetector.detect(samples: ordered, sampleRate: ctx.sampleRate) {
        _ = ctx.pitchResultQueue.enqueue(result)
    }
    ctx.samplesAccumulated = 0
    return noErr
}

// MARK: - KaraokeEngine

final class KaraokeEngine {
    private var vpio: AudioUnit?
    private let context = KaraokeContext()
    private(set) var isRunning = false
    private(set) var setupError: String?
    private(set) var sampleRate: Double = 0

    var onPitchDetected: ((PitchResult) -> Void)?

    // MARK: - セットアップ

    func setup() {
        setupError = nil
        let session = AVAudioSession.sharedInstance()
        do {
            // playAndRecord + defaultToSpeaker でスピーカーから BGM を鳴らす
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            setupError = "AVAudioSession: \(error.localizedDescription)"
            return
        }
        sampleRate = session.sampleRate
        context.sampleRate = sampleRate

        guard createVPIO()       else { setupError = "VPIO: 生成失敗"; return }
        guard configureIO()      else { setupError = "IO: 設定失敗"; return }
        guard setStreamFormats() else { setupError = "Format: 設定失敗"; return }
        guard setCallbacks()     else { setupError = "Callback: 設定失敗"; return }

        guard AudioUnitInitialize(vpio!) == noErr else {
            setupError = "Initialize: 失敗"; return
        }
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
        _ = context.bgmCommandQueue.enqueue(0)  // BGM を停止
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

    // BGM の周波数を更新（UI スレッドから呼ぶ）
    func setBGMFrequency(_ hz: Double) {
        _ = context.bgmCommandQueue.enqueue(hz)
    }

    func pollResults() {
        while let result = context.pitchResultQueue.dequeue() {
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
        var enable: UInt32 = 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        // Bus 0 (Output) を有効化 → BGM をスピーカーへ
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0, &enable, size) == noErr else { return false }
        // Bus 1 (Input) を有効化 → マイクから声を取り込む
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1, &enable, size) == noErr else { return false }
        return true
    }

    private func setStreamFormats() -> Bool {
        guard let au = vpio else { return false }
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
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // Bus 0 Input Scope = アプリ→スピーカーへ書き込む側のフォーマット
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 0, &asbd, size) == noErr else { return false }
        // Bus 1 Output Scope = マイク→アプリへ出てくる側のフォーマット
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &asbd, size) == noErr else { return false }
        return true
    }

    private func setCallbacks() -> Bool {
        guard let au = vpio else { return false }
        let refCon = Unmanaged.passUnretained(context).toOpaque()

        // Bus 0: BGM レンダーコールバック（Step 3 の RenderCallback と同じ仕組み）
        var renderCB = AURenderCallbackStruct(inputProc: bgmRenderCallback, inputProcRefCon: refCon)
        guard AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, 0,
                                   &renderCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
        else { return false }

        // Bus 1: マイク入力コールバック（Step 6 と同じ仕組み）
        var inputCB = AURenderCallbackStruct(inputProc: micInputCallback, inputProcRefCon: refCon)
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0,
                                   &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
        else { return false }

        return true
    }
}
