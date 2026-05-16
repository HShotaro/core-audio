import AVFoundation
import Observation

@Observable
final class Step2ViewModel {
    var componentSubType: String = ""
    var properties: VPIOPropertyInfo?
    var errorMessage: String?

    private var vpio: AudioUnit?

    func createAndInspect() {
        errorMessage = nil
        setupAudioSession()

        guard let au = VPIOInspector.createVPIO() else {
            errorMessage = "VPIO: インスタンス生成に失敗しました（実機で試してください）"
            return
        }
        vpio = au
        componentSubType = VPIOInspector.componentSubType(of: au)
        properties = VPIOInspector.readProperties(of: au)
    }

    func toggleBypass() {
        guard let au = vpio, let props = properties else { return }
        VPIOInspector.setBypass(au, enabled: !props.isBypassEnabled)
        properties = VPIOInspector.readProperties(of: au)
    }

    func toggleAGC() {
        guard let au = vpio, let props = properties else { return }
        VPIOInspector.setAGC(au, enabled: !props.isAGCEnabled)
        properties = VPIOInspector.readProperties(of: au)
    }

    func toggleMute() {
        guard let au = vpio, let props = properties else { return }
        VPIOInspector.setMute(au, enabled: !props.isMuted)
        properties = VPIOInspector.readProperties(of: au)
    }

    func cleanup() {
        if let au = vpio { VPIOInspector.dispose(au); vpio = nil }
        componentSubType = ""
        properties = nil
    }

    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
