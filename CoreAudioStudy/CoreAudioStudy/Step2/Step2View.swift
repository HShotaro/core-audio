import SwiftUI

struct Step2View: View {
    @State private var vm = Step2ViewModel()

    var body: some View {
        List {
            controlSection
            if let error = vm.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }
            if !vm.componentSubType.isEmpty {
                identitySection
            }
            if let props = vm.properties {
                propertiesSection(props)
                aecExplanationSection
            }
        }
        .navigationTitle("Step 2: VPIO の内側")
        .onDisappear { vm.cleanup() }
    }

    // MARK: - Sections

    private var controlSection: some View {
        Section("操作") {
            Button("VPIO を生成して検査") { vm.createAndInspect() }
            Button("インスタンスを破棄") { vm.cleanup() }
                .foregroundStyle(.red)
        }
    }

    private var identitySection: some View {
        Section {
            row("componentType",    "auou  ← RemoteIOと同じ")
            row("componentSubType", "\(vm.componentSubType)  ← RemoteIOは rioc")
        } header: {
            Text("正体（AudioComponentDescription）")
        } footer: {
            Text("VPIO は RemoteIO の上に DSP チェーンを追加したもの。バス構造は同一。")
                .font(.caption)
        }
    }

    private func propertiesSection(_ props: VPIOPropertyInfo) -> some View {
        Section {
            propertyRow(
                label: "BypassVoiceProcessing",
                description: "AEC・AGC・VAD をまとめてOFF",
                value: props.isBypassEnabled,
                action: { vm.toggleBypass() }
            )
            propertyRow(
                label: "VoiceProcessingEnableAGC",
                description: "Auto Gain Control（音量自動調整）",
                value: props.isAGCEnabled,
                action: { vm.toggleAGC() }
            )
            propertyRow(
                label: "MuteOutput",
                description: "出力ミュート",
                value: props.isMuted,
                action: { vm.toggleMute() }
            )
        } header: {
            Text("VPIO 固有プロパティ（kAUVoiceIOProperty_*）")
        } footer: {
            Text("Bypass=ON にすると AEC が無効になりエコーが発生する。これが VPIO の存在理由。")
                .font(.caption)
        }
    }

    private var aecExplanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("なぜコラボ配信に VPIO が必要か").font(.headline)
                Text("""
                相手の声がスピーカーから流れる
                　　↓
                マイクがスピーカー音を拾う（エコー）
                　　↓
                AEC がスピーカー出力を「参照信号」として
                マイク入力から差し引く
                　　↓
                相手に自分の声だけが届く
                """)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                Text("VPIO は I/O を担うため出力信号（参照信号）とマイク入力の両方に同時アクセスできる。これが RemoteIO では AEC が実現できない理由。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("AEC（Acoustic Echo Cancellation）の原理")
        }
    }

    // MARK: - Helpers

    private func propertyRow(label: String, description: String, value: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption.monospaced())
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(value ? "ON" : "OFF") { action() }
                    .buttonStyle(.bordered)
                    .tint(value ? .green : .gray)
            }
        }
        .padding(.vertical, 2)
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
    NavigationStack { Step2View() }
}
