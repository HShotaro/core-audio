import SwiftUI

struct Step7View: View {
    @State private var vm = Step7ViewModel()

    var body: some View {
        List {
            if let error = vm.setupError {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }
            controlSection
            currentNoteSection
            progressSection
            scoreHistorySection
            converterSection
        }
        .navigationTitle("Step 7: 採点エンジン")
        .onAppear { vm.setup() }
        .onDisappear { vm.cleanup() }
    }

    // MARK: - Sections

    private var controlSection: some View {
        Section("操作") {
            // オクターブシフト（歌い始める前のみ変更可）
            HStack {
                Text("オクターブ")
                Spacer()
                Stepper(
                    octaveShiftLabel,
                    value: $vm.octaveShift,
                    in: -2...2
                )
                .disabled(vm.isRunning)
                .fixedSize()
            }
            if !vm.isRunning && !vm.isFinished {
                Button("歌い始める") { vm.startSinging() }
                    .foregroundStyle(.blue)
            }
            if vm.isRunning {
                Button("停止") { vm.stop() }
                    .foregroundStyle(.red)
            }
            if vm.isFinished || (!vm.isRunning && !vm.noteScores.isEmpty) {
                Button("リセット") { vm.reset() }
                    .foregroundStyle(.orange)
            }
        }
    }

    private var octaveShiftLabel: String {
        switch vm.octaveShift {
        case 0:  return "標準 (Oct 3)"
        case 1:  return "+1 (Oct 4)"
        case 2:  return "+2 (Oct 5)"
        case -1: return "-1 (Oct 2)"
        case -2: return "-2 (Oct 1)"
        default: return "\(vm.octaveShift > 0 ? "+" : "")\(vm.octaveShift)"
        }
    }

    private var currentNoteSection: some View {
        Section {
            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("歌うべき音").font(.caption).foregroundStyle(.secondary)
                    Text(vm.currentExpectedNote?.noteName ?? "--")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("検出中の音").font(.caption).foregroundStyle(.secondary)
                    Text(vm.currentDetectedNote)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(noteMatchColor)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
        } header: {
            Text("リアルタイム比較")
        }
    }

    private var progressSection: some View {
        Section {
            VStack(spacing: 8) {
                // プログレスバー
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue)
                            .frame(width: geo.size.width * CGFloat(vm.progress))
                    }
                    .frame(height: 8)
                }
                .frame(height: 8)

                // ノート一覧（メロディ）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(vm.transposedMelody.enumerated()), id: \.offset) { _, note in
                            noteChip(note)
                        }
                    }
                }

                // 総合スコア
                if !vm.noteScores.isEmpty {
                    HStack {
                        Text("総合スコア")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.0f 点", vm.totalScore))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(scoreColor(vm.totalScore))
                    }
                }

                if vm.isFinished {
                    Text("完了！").font(.title2.bold()).foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("進行状況・スコア")
        }
    }

    private var scoreHistorySection: some View {
        Section {
            ForEach(Array(vm.noteScores.enumerated()), id: \.offset) { _, ns in
                HStack {
                    Text(ns.expected.noteName)
                        .font(.caption.monospaced().bold())
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f Hz → %.1f Hz", ns.expected.frequency, ns.detectedHz))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(String(format: "誤差 %.0f cents", ns.centsError))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.0f", ns.score))
                        .font(.caption.bold())
                        .foregroundStyle(scoreColor(ns.score))
                }
            }
        } header: {
            Text("音符ごとのスコア")
        }
    }

    private var converterSection: some View {
        Section {
            Button("AudioConverter デモを実行") { vm.runConverterDemo() }
                .foregroundStyle(.purple)

            if let result = vm.converterResult {
                VStack(alignment: .leading, spacing: 4) {
                    row("変換前", result.inputFormat)
                    row("変換後", result.outputFormat)
                    row("入力サンプル数", "\(result.inputSamples)")
                    row("出力サンプル数", "\(result.outputSamples)")
                    row("サンプル数の比",
                        String(format: "%.4f（≒ 44100/sampleRate）",
                               Double(result.outputSamples) / Double(result.inputSamples)))
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("AudioConverter API（フォーマット変換）")
        } footer: {
            Text("Float32 / 48000 Hz → Int16 / 44100 Hz への変換。\nファイル保存や低帯域通信向けにフォーマットを変換するときに使う。")
                .font(.caption)
        }
    }

    // MARK: - Helpers

    private func noteChip(_ note: NoteEvent) -> some View {
        let isScored = vm.noteScores.contains {
            $0.expected.noteName == note.noteName && $0.expected.startBeat == note.startBeat
        }
        let score = vm.noteScores.first {
            $0.expected.noteName == note.noteName && $0.expected.startBeat == note.startBeat
        }?.score
        let isCurrent = vm.currentExpectedNote?.startBeat == note.startBeat

        return VStack(spacing: 2) {
            Text(note.noteName)
                .font(.caption.bold())
                .foregroundStyle(isCurrent ? .white : .primary)
            if let s = score {
                Text("\(Int(s))")
                    .font(.system(size: 9))
                    .foregroundStyle(isCurrent ? .white : scoreColor(s))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.blue :
                      isScored ? scoreColor(score ?? 0).opacity(0.2) :
                      Color.secondary.opacity(0.1))
        )
    }

    private var noteMatchColor: Color {
        guard let expected = vm.currentExpectedNote else { return .secondary }
        let base = expected.noteName.prefix(while: { !$0.isNumber })
        let detected = vm.currentDetectedNote.prefix(while: { !$0.isNumber })
        return base == detected ? .green : .red
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 80 { return .green }
        if score >= 50 { return .orange }
        return .red
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).font(.caption.monospaced())
        }
    }
}

#Preview {
    NavigationStack { Step7View() }
}
