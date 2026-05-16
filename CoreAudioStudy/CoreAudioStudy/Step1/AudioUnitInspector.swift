import AudioToolbox

struct AUInfo {
    let label: String
    let componentType: String
    let componentSubType: String
    let sampleRate: Double
    let pointer: String
}

struct ASBDInfo {
    let sampleRate: Double
    let formatID: String
    let formatFlags: String
    let bitsPerChannel: UInt32
    let channelsPerFrame: UInt32
    let bytesPerFrame: UInt32
    let framesPerPacket: UInt32
    let bytesPerPacket: UInt32
}

enum AudioUnitInspector {

    // MARK: - Component の検索

    static func findComponent(type: OSType, subType: OSType) -> AudioComponent? {
        var desc = AudioComponentDescription(
            componentType:         type,
            componentSubType:      subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        return AudioComponentFindNext(nil, &desc)
    }

    // MARK: - インスタンス生成

    static func createInstance(component: AudioComponent) -> AudioUnit? {
        var au: AudioUnit?
        guard AudioComponentInstanceNew(component, &au) == noErr, let au else { return nil }
        guard AudioUnitInitialize(au) == noErr else {
            AudioComponentInstanceDispose(au)
            return nil
        }
        return au
    }

    static func disposeInstance(_ au: AudioUnit) {
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
    }

    // MARK: - AU情報の取得

    static func auInfo(from au: AudioUnit, label: String) -> AUInfo {
        let component = AudioComponentInstanceGetComponent(au)
        var desc = AudioComponentDescription()
        AudioComponentGetDescription(component, &desc)

        return AUInfo(
            label: label,
            componentType: fourCC(desc.componentType),
            componentSubType: fourCC(desc.componentSubType),
            sampleRate: getSampleRate(of: au, scope: kAudioUnitScope_Output, bus: 0),
            pointer: "\(au)"
        )
    }

    // MARK: - サンプルレートの取得

    static func getSampleRate(of au: AudioUnit, scope: AudioUnitScope, bus: AudioUnitElement) -> Double {
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(au, kAudioUnitProperty_SampleRate, scope, bus, &sampleRate, &size)
        return sampleRate
    }

    // MARK: - ASBDの取得

    static func getASBD(of au: AudioUnit, scope: AudioUnitScope, bus: AudioUnitElement) -> ASBDInfo? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            scope,
            bus,
            &asbd,
            &size
        )
        guard status == noErr else { return nil }

        return ASBDInfo(
            sampleRate: asbd.mSampleRate,
            formatID: fourCC(asbd.mFormatID),
            formatFlags: formatFlagsDescription(asbd.mFormatFlags, formatID: asbd.mFormatID),
            bitsPerChannel: asbd.mBitsPerChannel,
            channelsPerFrame: asbd.mChannelsPerFrame,
            bytesPerFrame: asbd.mBytesPerFrame,
            framesPerPacket: asbd.mFramesPerPacket,
            bytesPerPacket: asbd.mBytesPerPacket
        )
    }

    // MARK: - RemoteIO の Bus 1 (Input) 有効化

    // RemoteIO はデフォルトでマイク入力が無効。
    // Bus 1 の ASBD を読む前に明示的に有効にする必要がある。
    static func enableRemoteIOInput(_ au: AudioUnit) {
        var enable: UInt32 = 1
        AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // Bus 1 = Input
            &enable,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    // MARK: - Helpers

    static func fourCC(_ code: UInt32) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >>  8) & 0xFF)!),
            Character(UnicodeScalar((code      ) & 0xFF)!),
        ]
        return String(chars)
    }

    static func formatFlagsDescription(_ flags: AudioFormatFlags, formatID: UInt32) -> String {
        guard formatID == kAudioFormatLinearPCM else {
            return String(format: "0x%08X", flags)
        }
        var parts: [String] = []
        if flags & kAudioFormatFlagIsFloat          != 0 { parts.append("Float") }
        if flags & kAudioFormatFlagIsSignedInteger  != 0 { parts.append("SignedInt") }
        if flags & kAudioFormatFlagIsPacked         != 0 { parts.append("Packed") }
        if flags & kAudioFormatFlagIsNonInterleaved != 0 { parts.append("NonInterleaved") }
        if flags & kAudioFormatFlagIsBigEndian      != 0 { parts.append("BigEndian") }
        return parts.isEmpty ? String(format: "0x%08X", flags) : parts.joined(separator: " | ")
    }
}
