import SwiftUI

struct Step3View: View {
    @State private var vm = Step3ViewModel()

    var body: some View {
        List {
            pullModelSection
            if let error = vm.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }
            if vm.sampleRate > 0 {
                controlSection
                frequencySection
                formatSection
            }
            realtimeThreadSection
        }
        .navigationTitle("Step 3: RenderCallback")
        .onAppear { vm.setup() }
        .onDisappear { vm.cleanup() }
    }

    // MARK: - Sections

    private var pullModelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                ハードウェア（スピーカー）
                    ↑ 音声データを要求（プル）
                RemoteIO AU
                    ↑ RenderCallback を呼ぶ
                アプリ（サイン波を生成して返す）
                """)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("プルモデル（Pull Model）")
        } footer: {
            Text("Core Audio はハードウェア側が主導。スピーカーが必要なタイミングで RenderCallback を呼び出し、アプリがデータを詰めて返す。AVAudioEngine.connect() は内部でこのコールバック連鎖を構築している。")
                .font(.caption)
        }
    }

    private var controlSection: some View {
        Section("再生") {
            Button(vm.isRunning ? "停止 (AudioOutputUnitStop)" : "再生 (AudioOutputUnitStart)") {
                vm.togglePlayback()
            }
            .foregroundStyle(vm.isRunning ? .red : .blue)
        }
    }

    private var frequencySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("周波数")
                    Spacer()
                    Text("\(Int(vm.frequency)) Hz")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { vm.frequency },
                    set: { vm.updateFrequency($0) }
                ), in: 220...880, step: 1)
                HStack {
                    ForEach([220, 330, 440, 660, 880], id: \.self) { hz in
                        Button("\(hz)") { vm.updateFrequency(Double(hz)) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("周波数コントロール")
        } footer: {
            Text("コールバック内で context.frequency を参照しているため、再生中でも即座に反映される。")
                .font(.caption)
        }
    }

    private var formatSection: some View {
        Section {
            row("sampleRate",       "\(Int(vm.sampleRate)) Hz")
            row("format",          "LinearPCM Float32")
            row("flags",           "Float | NonInterleaved")
            row("channelsPerFrame", "2 ch（ステレオ）")
            row("コールバックScope",  "kAudioUnitScope_Input, Bus 0")
        } header: {
            Text("設定したフォーマット（ASBD）")
        } footer: {
            Text("setStreamFormat で RemoteIO Bus 0 に設定したものと同じフォーマットでコールバックが呼ばれる。")
                .font(.caption)
        }
    }

    private var realtimeThreadSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("コールバックはリアルタイムスレッドで実行される。\n以下は禁止操作（詳細は Step 4）。")
                    .font(.caption)
                Group {
                    badRow("malloc / free（メモリ確保・解放）")
                    badRow("ObjC メッセージ送信（@objc メソッド）")
                    badRow("mutex / lock の取得")
                    badRow("ファイルI/O / ネットワーク")
                    badRow("Swift クラスの retain/release")
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("リアルタイムスレッドの制約（入門）")
        }
    }

    // MARK: - Helpers

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value).font(.caption.monospaced())
        }
    }

    private func badRow(_ text: String) -> some View {
        Label(text, systemImage: "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
    }
}

#Preview {
    NavigationStack { Step3View() }
}
