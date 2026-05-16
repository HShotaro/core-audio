import SwiftUI

struct Step4View: View {
    @State private var vm = Step4ViewModel()

    var body: some View {
        List {
            problemSection
            solutionSection
            if let error = vm.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }
            if vm.sampleRate > 0 {
                controlSection
                frequencySection
                volumeSection
            }
            spscSection
        }
        .navigationTitle("Step 4: リアルタイムスレッド")
        .onAppear { vm.setup() }
        .onDisappear { vm.cleanup() }
    }

    // MARK: - Sections

    private var problemSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 3 の問題点").font(.headline)
                Text("context.frequency = newValue").font(.caption.monospaced())
                    .padding(4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
                Text("UI スレッドからオーディオスレッドが参照する変数を直接書き換えている。両スレッドが同時にアクセスするとデータ競合が起きる。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("問題: 安全でないスレッド間データ共有")
        }
    }

    private var solutionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 4 の解決策").font(.headline)
                Text("""
                UIスレッド
                    ↓ enqueue（ロックなし・mallocなし）
                LockFreeQueue（SPSC Ring Buffer）
                    ↓ dequeue（ロックなし・mallocなし）
                オーディオスレッド（コールバック冒頭で処理）
                """)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("解決: LockFreeQueue 経由でコマンドを渡す")
        }
    }

    private var controlSection: some View {
        Section("再生") {
            Button(vm.isRunning ? "停止" : "再生") { vm.togglePlayback() }
                .foregroundStyle(vm.isRunning ? .red : .blue)
            row("sampleRate", "\(Int(vm.sampleRate)) Hz")
        }
    }

    private var frequencySection: some View {
        Section {
            HStack {
                Text("周波数")
                Spacer()
                Text("\(Int(vm.frequency)) Hz").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { vm.frequency },
                set: { vm.updateFrequency($0) }
            ), in: 220...880, step: 1)
            HStack {
                ForEach([220, 330, 440, 660, 880], id: \.self) { hz in
                    Button("\(hz)") { vm.updateFrequency(Double(hz)) }
                        .buttonStyle(.bordered).font(.caption)
                }
            }
        } header: {
            Text("周波数（LockFreeQueue 経由）")
        } footer: {
            Text("変更は enqueue → コールバック冒頭の dequeue → ctx.frequency 更新 の順で安全に反映される。")
                .font(.caption)
        }
    }

    private var volumeSection: some View {
        Section {
            HStack {
                Text("音量")
                Spacer()
                Text(String(format: "%.2f", vm.volume)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(vm.volume) },
                set: { vm.updateVolume(Float($0)) }
            ), in: 0...1, step: 0.01)
        } header: {
            Text("音量（LockFreeQueue 経由）")
        }
    }

    private var spscSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                spscRow("writeIndex", description: "Producer（UIスレッド）のみ更新", color: .blue)
                spscRow("readIndex",  description: "Consumer（オーディオスレッド）のみ更新", color: .orange)
                Text("各スレッドが別々のインデックスだけを更新するためロック不要。これが SPSC の安全性の根拠。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("SPSC Ring Buffer の仕組み")
        }
    }

    // MARK: - Helpers

    private func spscRow(_ label: String, description: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption.monospaced()).foregroundStyle(color)
                .frame(width: 100, alignment: .leading)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value).font(.caption.monospaced())
        }
    }
}

#Preview {
    NavigationStack { Step4View() }
}
