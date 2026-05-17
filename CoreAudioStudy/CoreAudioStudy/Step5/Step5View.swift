import SwiftUI

struct Step5View: View {
    @State private var vm = Step5ViewModel()

    var body: some View {
        List {
            spectrumSection
            signalSection
            fftExplanationSection
            filterExplanationSection
        }
        .navigationTitle("Step 5: FFT・フィルター")
        .onAppear { vm.setup() }
        .onDisappear { vm.cleanup() }
    }

    // MARK: - Sections

    private var spectrumSection: some View {
        Section {
            if vm.spectrum.isEmpty {
                Text("シグナルを選択して再生してください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SpectrumView(
                    magnitudes: Array(vm.spectrum.prefix(vm.displayBinCount)),
                    displayBinCount: vm.displayBinCount,
                    sampleRate: vm.sampleRate,
                    fftSize: 2048
                )
                .frame(height: 160)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        } header: {
            Text("周波数スペクトル（0 〜 5 kHz）")
        } footer: {
            Text("縦軸: dB（0 が最大、-80 が最小）　横軸: 周波数")
                .font(.caption)
        }
    }

    private var signalSection: some View {
        Section("シグナル選択") {
            ForEach(Step5Engine.Signal.allCases, id: \.self) { signal in
                Button {
                    vm.play(signal)
                } label: {
                    HStack {
                        Text(signal.rawValue).font(.callout)
                        Spacer()
                        if vm.isRunning && vm.currentSignal == signal {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            if vm.isRunning {
                Button("停止") { vm.stop() }
                    .foregroundStyle(.red)
            }
        }
    }

    private var fftExplanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                explanationRow("単音 (440 Hz)",
                               "スペクトルに 440 Hz の位置だけスパイクが立つ")
                explanationRow("和音 (440 + 880 + 1320 Hz)",
                               "3つの周波数にスパイクが立つ（倍音の関係）")
                explanationRow("一次IIR LPF 適用後",
                               "880 Hz・1320 Hz が緩やかに減衰（-20 dB/decade）")
                explanationRow("Biquad LPF 適用後",
                               "880 Hz・1320 Hz がより急峻に減衰（-40 dB/decade）。一次IIRと比較するとスパイクの落ち方が明確に違う")
            }
            .padding(.vertical, 4)
        } header: {
            Text("FFT で確認できること")
        } footer: {
            Text("FFT は「どの周波数成分がどれだけ含まれているか」を可視化する。カラオケのピッチ検出はこのスパイク位置から基本周波数を特定する。")
                .font(.caption)
        }
    }

    private var filterExplanationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                // 一次IIR
                VStack(alignment: .leading, spacing: 4) {
                    Text("一次 IIR ローパスフィルター").font(.headline)
                    Text("y[n] = α × x[n] + (1 - α) × y[n-1]")
                        .font(.caption.monospaced())
                        .padding(4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    Text("α = 2π × fc / (2π × fc + fs)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("ロールオフ: -20 dB/decade。前サンプルの出力を混ぜ続けることで高周波が緩やかに減衰する。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                // Biquad
                VStack(alignment: .leading, spacing: 4) {
                    Text("Biquad ローパスフィルター（二次バターワース）").font(.headline)
                    Text("H(z) = (b0 + b1z⁻¹ + b2z⁻²) / (1 + a1z⁻¹ + a2z⁻²)")
                        .font(.caption.monospaced())
                        .padding(4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    Text("ロールオフ: -40 dB/decade（一次IIRの2倍の急峻さ）")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Q = 1/√2（バターワース特性）のとき通過域が最もフラット。EQ・ディストーションで広く使われる。vDSP_biquad で実装。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                // 比較表
                VStack(alignment: .leading, spacing: 4) {
                    Text("フィルター比較").font(.headline)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text("").frame(width: 90)
                            Text("一次IIR").font(.caption.bold())
                            Text("Biquad").font(.caption.bold())
                        }
                        VStack(alignment: .leading) {
                            Text("ロールオフ").font(.caption).foregroundStyle(.secondary)
                            Text("-20 dB/dec").font(.caption.monospaced())
                            Text("-40 dB/dec").font(.caption.monospaced())
                        }
                        VStack(alignment: .leading) {
                            Text("次数").font(.caption).foregroundStyle(.secondary)
                            Text("1次").font(.caption.monospaced())
                            Text("2次").font(.caption.monospaced())
                        }
                        VStack(alignment: .leading) {
                            Text("係数数").font(.caption).foregroundStyle(.secondary)
                            Text("1個(α)").font(.caption.monospaced())
                            Text("5個").font(.caption.monospaced())
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("フィルターの仕組み")
        }
    }

    // MARK: - Helpers

    private func explanationRow(_ label: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.bold())
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Spectrum Visualizer

struct SpectrumView: View {
    let magnitudes: [Float]
    let displayBinCount: Int
    let sampleRate: Double
    let fftSize: Int

    var body: some View {
        Canvas { context, size in
            guard !magnitudes.isEmpty else { return }
            let count = magnitudes.count
            let barWidth = size.width / CGFloat(count)

            for (i, magnitude) in magnitudes.enumerated() {
                // -80 dB → 0, 0 dB → 1 に正規化
                let normalized = CGFloat((magnitude + 80.0) / 80.0)
                let barHeight = max(1, normalized * size.height)
                let x = CGFloat(i) * barWidth
                let y = size.height - barHeight
                let rect = CGRect(x: x, y: y, width: max(1, barWidth - 0.5), height: barHeight)

                // 周波数に応じて色を変える
                let freq = Double(i) * sampleRate / Double(fftSize)
                let hue = min(0.7, freq / 5000 * 0.7) // 青→赤
                context.fill(Path(rect), with: .color(Color(hue: hue, saturation: 0.8, brightness: 0.9)))
            }

            // 周波数軸ラベル（500 Hz ごと）
            let stride = Int(500.0 / (sampleRate / Double(fftSize)))
            var labelBin = stride
            while labelBin < count {
                let x = CGFloat(labelBin) * barWidth
                let freq = Double(labelBin) * sampleRate / Double(fftSize)
                let label = freq >= 1000 ? String(format: "%.0fk", freq / 1000) : "\(Int(freq))"
                context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: x, y: size.height - 6))
                labelBin += stride
            }
        }
    }
}

#Preview {
    NavigationStack { Step5View() }
}
