import AVFoundation
import AudioToolbox

// Step 3 との比較:
// Step 3: context.frequency を UI スレッドから直接書き換えていた（安全でない）
// Step 4: LockFreeQueue 経由で周波数変更コマンドをオーディオスレッドに渡す（安全）

enum AudioCommand {
    case setFrequency(Double)
    case setVolume(Float)
}

final class SafeSineContext {
    var phase: Double = 0
    var frequency: Double = 440
    var volume: Float = 0.5
    var sampleRate: Double = 48000
    // コールバックが直接参照するキュー（Consumer側）
    let commandQueue = LockFreeQueue<AudioCommand>()
}

private let safeRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<SafeSineContext>.fromOpaque(inRefCon).takeUnretainedValue()

    // コールバック冒頭でキューからコマンドを処理する
    // dequeue はロックなし・malloc なし → リアルタイムスレッド安全
    while let command = ctx.commandQueue.dequeue() {
        switch command {
        case .setFrequency(let hz): ctx.frequency = hz
        case .setVolume(let vol):   ctx.volume = vol
        }
    }

    let phaseIncrement = 2.0 * Double.pi * ctx.frequency / ctx.sampleRate
    let ablPointer = UnsafeMutableAudioBufferListPointer(ioData)
    for buffer in ablPointer {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float32.self)
        for frame in 0..<Int(inNumberFrames) {
            samples[frame] = Float32(sin(ctx.phase)) * ctx.volume
            ctx.phase += phaseIncrement
        }
    }
    ctx.phase = ctx.phase.truncatingRemainder(dividingBy: 2.0 * Double.pi)
    return noErr
}

final class SafeRenderEngine {
    private var remoteIO: AudioUnit?
    private let context = SafeSineContext()
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    private(set) var setupError: String?

    // UIスレッドからコマンドを送る（enqueue はロックフリー）
    func sendCommand(_ command: AudioCommand) {
        _ = context.commandQueue.enqueue(command)
    }

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

        guard createRemoteIO()    else { setupError = "RemoteIO: 生成失敗"; return }
        guard setStreamFormat()   else { setupError = "StreamFormat: 設定失敗"; return }
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

    // MARK: - Private

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

    private func setRenderCallback() -> Bool {
        guard let au = remoteIO else { return false }
        var callbackStruct = AURenderCallbackStruct(
            inputProc:       safeRenderCallback,
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
