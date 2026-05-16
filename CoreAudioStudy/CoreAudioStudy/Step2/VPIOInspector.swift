import AudioToolbox

struct VPIOPropertyInfo {
    let isBypassEnabled: Bool      // AEC・AGC等のDSP処理をすべてバイパス
    let isAGCEnabled: Bool         // AGC (Auto Gain Control) の有効/無効
    let isMuted: Bool              // 出力のミュート状態
}

enum VPIOInspector {

    // MARK: - インスタンス生成

    // RemoteIO との違いは componentSubType が vpio になるだけ。
    // バス構造（Bus 0=Output, Bus 1=Input）はRemoteIOと同じ。
    static func createVPIO() -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_VoiceProcessingIO, // "vpio"
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }

        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au else { return nil }

        // Bus 1（マイク入力）を有効化 — RemoteIOと同じ手順
        var enable: UInt32 = 1
        AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enable,
            UInt32(MemoryLayout<UInt32>.size)
        )

        guard AudioUnitInitialize(au) == noErr else {
            AudioComponentInstanceDispose(au)
            return nil
        }
        return au
    }

    static func dispose(_ au: AudioUnit) {
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
    }

    // MARK: - ComponentDescription の取得

    static func componentSubType(of au: AudioUnit) -> String {
        let comp = AudioComponentInstanceGetComponent(au)
        var desc = AudioComponentDescription()
        AudioComponentGetDescription(comp, &desc)
        return fourCC(desc.componentSubType)
    }

    // MARK: - VPIOプロパティの読み取り

    static func readProperties(of au: AudioUnit) -> VPIOPropertyInfo {
        return VPIOPropertyInfo(
            isBypassEnabled: readUInt32(au, kAUVoiceIOProperty_BypassVoiceProcessing) == 1,
            isAGCEnabled:    readUInt32(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC) == 1,
            isMuted:         readUInt32(au, kAUVoiceIOProperty_MuteOutput) == 1
        )
    }

    // MARK: - VPIOプロパティの書き込み

    // AEC・AGC・VAD をまとめてバイパス（1=バイパスON=DSP無効）
    static func setBypass(_ au: AudioUnit, enabled: Bool) {
        var value: UInt32 = enabled ? 1 : 0
        AudioUnitSetProperty(
            au,
            kAUVoiceIOProperty_BypassVoiceProcessing,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    static func setAGC(_ au: AudioUnit, enabled: Bool) {
        var value: UInt32 = enabled ? 1 : 0
        AudioUnitSetProperty(
            au,
            kAUVoiceIOProperty_VoiceProcessingEnableAGC,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    static func setMute(_ au: AudioUnit, enabled: Bool) {
        var value: UInt32 = enabled ? 1 : 0
        AudioUnitSetProperty(
            au,
            kAUVoiceIOProperty_MuteOutput,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    // MARK: - Helpers

    private static func readUInt32(_ au: AudioUnit, _ property: AudioUnitPropertyID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(au, property, kAudioUnitScope_Global, 0, &value, &size)
        return value
    }

    private static func fourCC(_ code: UInt32) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >>  8) & 0xFF)!),
            Character(UnicodeScalar((code      ) & 0xFF)!),
        ]
        return String(chars)
    }
}
