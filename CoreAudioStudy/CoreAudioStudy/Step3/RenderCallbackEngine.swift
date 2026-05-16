import AVFoundation
import AudioToolbox

// コールバックに渡すコンテキスト（参照型で inRefCon 経由で共有）
final class SineWaveContext {
    var phase: Double = 0
    var frequency: Double = 440
    var sampleRate: Double = 48000
}

// C関数ポインタとして渡すコールバック。
// キャプチャなしのクロージャのみ C 関数ポインタとして使用可能。
// コンテキストは inRefCon 経由で受け取る。
private let sineWaveRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    guard let ioData else { return noErr }

    // inRefCon（void*）から SineWaveContext を復元
    let ctx = Unmanaged<SineWaveContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let phaseIncrement = 2.0 * Double.pi * ctx.frequency / ctx.sampleRate

    // NonInterleaved: チャンネルごとに別バッファ（Step 1 の ASBD で確認した構造）
    let ablPointer = UnsafeMutableAudioBufferListPointer(ioData)
    for buffer in ablPointer {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float32.self)
        for frame in 0..<Int(inNumberFrames) {
            samples[frame] = Float32(sin(ctx.phase))
            ctx.phase += phaseIncrement
        }
    }
    // 位相のオーバーフロー防止（2πを超えたら折り返す）
    ctx.phase = ctx.phase.truncatingRemainder(dividingBy: 2.0 * Double.pi)

    return noErr
}

final class RenderCallbackEngine {
    private var remoteIO: AudioUnit?
    private let context = SineWaveContext()
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    private(set) var setupError: String?

    var frequency: Double {
        get { context.frequency }
        set { context.frequency = newValue }
    }

    // MARK: - ライフサイクル

    func setup() {
        setupError = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            setupError = "AVAudioSession: \(error.localizedDescription)"
            return
        }
        sampleRate = session.sampleRate
        context.sampleRate = sampleRate

        guard createRemoteIO()   else { setupError = "RemoteIO: 生成失敗"; return }
        guard setStreamFormat()  else { setupError = "StreamFormat: 設定失敗"; return }
        guard setRenderCallback() else { setupError = "RenderCallback: 設定失敗"; return }
    }

    func start() {
        guard let au = remoteIO else { return }
        AudioOutputUnitStart(au)
        isRunning = true
    }

    func stop() {
        guard let au = remoteIO else { return }
        AudioOutputUnitStop(au)
        isRunning = false
    }

    func dispose() {
        stop()
        if let au = remoteIO {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            remoteIO = nil
        }
    }

    // MARK: - C API セットアップ

    private func createRemoteIO() -> Bool {
        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return false }
        guard AudioComponentInstanceNew(comp, &remoteIO) == noErr else { return false }
        guard AudioUnitInitialize(remoteIO!) == noErr else { return false }
        return true
    }

    // RemoteIO の Bus 0 (kAudioUnitScope_Input) に出力フォーマットを設定する。
    // AVAudioEngine.connect(_:to:format:) がやっていることに相当。
    private func setStreamFormat() -> Bool {
        guard let au = remoteIO else { return false }
        var asbd = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: 2,
            mBitsPerChannel:   32,
            mReserved:         0
        )
        return AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr
    }

    // RemoteIO の Bus 0 にレンダーコールバックを登録する。
    // AVAudioEngine.connect(_:to:) がやっていることに相当。
    // コンテキストは Unmanaged で void* に変換して inRefCon に渡す。
    private func setRenderCallback() -> Bool {
        guard let au = remoteIO else { return false }
        var callbackStruct = AURenderCallbackStruct(
            inputProc:       sineWaveRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        return AudioUnitSetProperty(
            au,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr
    }
}
