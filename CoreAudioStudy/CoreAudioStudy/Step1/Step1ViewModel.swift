import AVFoundation
import AudioToolbox
import Observation

struct RemoteIOBusInfo {
    let outputBus0ASBD: ASBDInfo?  // Bus 0: スピーカーへ送る側 (kAudioUnitScope_Input)
    let inputBus1ASBD:  ASBDInfo?  // Bus 1: マイクから受け取る側 (kAudioUnitScope_Output)
}

@Observable
final class Step1ViewModel {
    var remoteIOInfo:  AUInfo?
    var mixerInfo:     AUInfo?
    var remoteIOBuses: RemoteIOBusInfo?
    var errorMessage:  String?

    // C APIで生成したAUインスタンスを保持
    private var remoteIO: AudioUnit?
    private var mixer:    AudioUnit?

    func inspect() {
        errorMessage = nil
        setupAudioSession()
        createRemoteIO()
        createMixer()
    }

    func cleanup() {
        if let au = remoteIO { AudioUnitInspector.disposeInstance(au); remoteIO = nil }
        if let au = mixer    { AudioUnitInspector.disposeInstance(au); mixer    = nil }
        remoteIOInfo  = nil
        mixerInfo     = nil
        remoteIOBuses = nil
    }

    // MARK: - Private

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func createRemoteIO() {
        guard let comp = AudioUnitInspector.findComponent(
            type:    kAudioUnitType_Output,
            subType: kAudioUnitSubType_RemoteIO
        ) else { errorMessage = "RemoteIO: component not found"; return }

        guard let au = AudioUnitInspector.createInstance(component: comp) else {
            errorMessage = "RemoteIO: instance creation failed"
            return
        }
        remoteIO = au

        // Bus 1 (Input) を有効化してから ASBD を読む
        AudioUnitInspector.enableRemoteIOInput(au)

        remoteIOInfo = AudioUnitInspector.auInfo(from: au, label: "RemoteIO")

        // AVAudioEngine との対応:
        //   Bus 0, kAudioUnitScope_Input  = outputNode がスピーカーへ書き込む側
        //   Bus 1, kAudioUnitScope_Output = inputNode がマイクから読み取る側
        remoteIOBuses = RemoteIOBusInfo(
            outputBus0ASBD: AudioUnitInspector.getASBD(of: au, scope: kAudioUnitScope_Input,  bus: 0),
            inputBus1ASBD:  AudioUnitInspector.getASBD(of: au, scope: kAudioUnitScope_Output, bus: 1)
        )
    }

    private func createMixer() {
        guard let comp = AudioUnitInspector.findComponent(
            type:    kAudioUnitType_Mixer,
            subType: kAudioUnitSubType_MultiChannelMixer
        ) else { errorMessage = "Mixer: component not found"; return }

        guard let au = AudioUnitInspector.createInstance(component: comp) else {
            errorMessage = "Mixer: instance creation failed"
            return
        }
        mixer = au
        mixerInfo = AudioUnitInspector.auInfo(from: au, label: "MultiChannelMixer")
    }
}
