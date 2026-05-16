import SwiftUI

struct Step1View: View {
    @State private var vm = Step1ViewModel()

    var body: some View {
        List {
            controlSection
            if let error = vm.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.caption.monospaced()) }
            }
            if let info = vm.remoteIOInfo {
                auInfoSection(info, correspondence: "AVAudioEngine の outputNode / inputNode")
            }
            if let buses = vm.remoteIOBuses {
                remoteIOBusSection(buses)
            }
            if let info = vm.mixerInfo {
                auInfoSection(info, correspondence: "AVAudioEngine の mainMixerNode")
            }
            mappingSection
        }
        .navigationTitle("Step 1: C API で AU を作る")
        .onDisappear { vm.cleanup() }
    }

    // MARK: - Sections

    private var controlSection: some View {
        Section {
            Button("AudioComponentFindNext → インスタンス生成 → 検査") {
                vm.inspect()
            }
            Button("インスタンスを破棄") {
                vm.cleanup()
            }
            .foregroundStyle(.red)
        } header: {
            Text("操作")
        }
    }

    private func auInfoSection(_ info: AUInfo, correspondence: String) -> some View {
        Section {
            row("componentType",    info.componentType)
            row("componentSubType", info.componentSubType)
            row("sampleRate",       "\(info.sampleRate) Hz")
            row("pointer",          info.pointer)
            row("AVAudioEngine",    correspondence)
        } header: {
            Text(info.label)
        }
    }

    private func remoteIOBusSection(_ buses: RemoteIOBusInfo) -> some View {
        Section {
            if let asbd = buses.outputBus0ASBD {
                Text("Bus 0 — Output (スピーカーへ)").font(.caption).foregroundStyle(.secondary)
                asbdRows(asbd)
            }
            Divider()
            if let asbd = buses.inputBus1ASBD {
                Text("Bus 1 — Input (マイクから)").font(.caption).foregroundStyle(.secondary)
                asbdRows(asbd)
            }
        } header: {
            Text("RemoteIO のバス構造 (ASBD)")
        } footer: {
            Text("inputNode と outputNode は同一の RemoteIO インスタンスの Bus 0 / Bus 1 に対応する")
                .font(.caption)
        }
    }

    private var mappingSection: some View {
        Section {
            row("outputNode",    "RemoteIO  Bus 0 (kAudioUnitScope_Input)")
            row("inputNode",     "RemoteIO  Bus 1 (kAudioUnitScope_Output)")
            row("mainMixerNode", "MultiChannelMixer")
            row("playerNode",    "ScheduledSoundPlayer (augn/acpn)")
        } header: {
            Text("AVAudioEngine ノードと Audio Unit の対応")
        }
    }

    // MARK: - Helpers

    private func asbdRows(_ asbd: ASBDInfo) -> some View {
        Group {
            row("mSampleRate",       "\(asbd.sampleRate) Hz")
            row("mFormatID",         asbd.formatID)
            row("mFormatFlags",      asbd.formatFlags)
            row("mBitsPerChannel",   "\(asbd.bitsPerChannel) bit")
            row("mChannelsPerFrame", "\(asbd.channelsPerFrame) ch")
            row("mBytesPerFrame",    "\(asbd.bytesPerFrame) bytes")
            row("mFramesPerPacket",  "\(asbd.framesPerPacket)")
            row("mBytesPerPacket",   "\(asbd.bytesPerPacket) bytes")
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

#Preview {
    NavigationStack { Step1View() }
}
