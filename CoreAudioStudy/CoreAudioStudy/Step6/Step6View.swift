import SwiftUI

struct Step6View: View {
    @State private var vm = Step6ViewModel()

    var body: some View {
        List {
            controlSection
            if let error = vm.setupError {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }
            pitchDisplaySection
            tunerSection
            hpsExplanationSection
        }
        .navigationTitle("Step 6: ピッチ検出")
        .onAppear { vm.setup() }
        .onDisappear { vm.cleanup() }
    }

    // MARK: - Sections

    private var controlSection: some View {
        Section("マイク") {
            Button(vm.isRunning ? "停止" : "検出開始") {
                vm.isRunning ? vm.stop() : vm.start()
            }
            .foregroundStyle(vm.isRunning ? .red : .blue)
            if vm.sampleRate > 0 {
                HStack {
                    Text("sampleRate").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(vm.sampleRate)) Hz").font(.caption.monospaced())
                }
            }
        }
    }

    private var pitchDisplaySection: some View {
        Section {
            VStack(spacing: 12) {
                // 音名（大きく表示）
                Text(vm.currentResult?.noteName ?? "--")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(noteColor)
                    .frame(maxWidth: .infinity)

                // 周波数
                HStack(spacing: 24) {
                    VStack(spacing: 2) {
                        Text("周波数").font(.caption).foregroundStyle(.secondary)
                        Text(vm.currentResult.map { String(format: "%.1f Hz", $0.frequency) } ?? "--")
                            .font(.caption.monospaced())
                    }
                    VStack(spacing: 2) {
                        Text("信頼度").font(.caption).foregroundStyle(.secondary)
                        Text(vm.currentResult.map { String(format: "%.0f%%", $0.confidence * 100) } ?? "--")
                            .font(.caption.monospaced())
                    }
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("検出結果")
        }
    }

    private var tunerSection: some View {
        Section {
            VStack(spacing: 8) {
                // セント偏差インジケーター（チューナー針）
                TunerNeedleView(cents: vm.currentResult?.cents ?? 0,
                                isActive: vm.currentResult != nil)
                    .frame(height: 60)

                HStack {
                    Text("-50").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("0 (完璧)").font(.caption2).foregroundStyle(.green)
                    Spacer()
                    Text("+50").font(.caption2).foregroundStyle(.secondary)
                }
                .font(.caption)

                if let cents = vm.currentResult?.cents {
                    Text(String(format: "%+.1f cents", cents))
                        .font(.caption.monospaced())
                        .foregroundStyle(abs(cents) < 10 ? .green : abs(cents) < 25 ? .orange : .red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("チューナー（セント偏差）")
        } footer: {
            Text("1 セント = 1/100 半音。±10 cents 以内が「ほぼ正確」の目安。")
                .font(.caption)
        }
    }

    private var hpsExplanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("HPS の仕組み").font(.headline)
                Text("""
                元スペクトル:  spike @ f0, 2f0, 3f0
                ÷2 圧縮:      spike @ f0←(2f0移動), 1.5f0
                ÷3 圧縮:      spike @ f0←(3f0移動)
                積:           f0 のスパイクだけが強調される
                """)
                .font(.caption.monospaced())
                .padding(6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                Text("単純な FFT ピーク検出では倍音を基本周波数と誤認しやすい。HPS は倍音を利用して基本周波数を強調するため精度が高い。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("HPS（Harmonic Product Spectrum）の原理")
        }
    }

    // MARK: - Helpers

    private var noteColor: Color {
        guard let cents = vm.currentResult?.cents else { return .secondary }
        if abs(cents) < 10  { return .green }
        if abs(cents) < 25  { return .orange }
        return .red
    }
}

// MARK: - チューナー針ビュー

struct TunerNeedleView: View {
    let cents: Double  // -50 〜 +50
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let clampedCents = max(-50, min(50, cents))
            let fraction = CGFloat((clampedCents + 50) / 100) // 0〜1
            let needleX = w * fraction

            ZStack(alignment: .leading) {
                // 背景バー
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 8)
                    .frame(maxWidth: .infinity)
                    .position(x: w / 2, y: h / 2)

                // 中央の基準線
                Rectangle()
                    .fill(Color.green.opacity(0.5))
                    .frame(width: 2, height: h * 0.8)
                    .position(x: w / 2, y: h / 2)

                // 針
                if isActive {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(needleColor)
                        .frame(width: 6, height: h * 0.9)
                        .position(x: needleX, y: h / 2)
                        .animation(.spring(response: 0.15), value: cents)
                }
            }
        }
    }

    private var needleColor: Color {
        if abs(cents) < 10  { return .green }
        if abs(cents) < 25  { return .orange }
        return .red
    }
}

#Preview {
    NavigationStack { Step6View() }
}
