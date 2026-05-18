# Step 7: 採点エンジン

## 学習目標

Step 6 のピッチ検出を採点ロジックと組み合わせ、BGM付きのリアルタイムカラオケ採点を実装する。
AudioConverter API（C API）でのフォーマット変換を理解する。
Step 1〜6 の知識が1つのアプリ機能として統合される。

---

## Step 1〜6 の知識の統合

```
【BGM出力】
ScoreEngine（基準ノート）→ KaraokeEngine.setBGMFrequency()
    ↓ LockFreeQueue（Step 4）
BGM RenderCallback（Step 3: RenderCallback の応用）
    ↓ Bus 0 Output → スピーカー

【マイク入力 + AEC】
スピーカー → マイク（エコー）
    ↓ VPIO の AEC がエコーを除去（Step 2）
マイク → Bus 1 InputCallback（Step 6）
    ↓ FFT + HPS（Step 5・6）
PitchResult → LockFreeQueue（Step 4）→ ScoreEngine → 採点
```

---

## 学べること

### 1. VPIO の入出力同時使用

Step 6 の `PitchEngine`（入力専用）を拡張し、BGM出力と AEC を同時に使う `KaraokeEngine` を実装した。

```swift
// Bus 0 (Output) を有効化 → BGM をスピーカーへ
AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                     kAudioUnitScope_Output, 0, &enable, size)

// Bus 1 (Input) を有効化 → マイクから声を取り込む
AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                     kAudioUnitScope_Input, 1, &enable, size)
```

VPIO の AEC は Bus 0 の出力を参照信号として自動的に Bus 1 のマイク入力からエコーを除去する。
これにより BGM がマイクに入っても採点に影響しない。

```
VPIO（単一インスタンス）
  Bus 0, RenderCallback → BGM サイン波をスピーカーへ送出
  Bus 1, InputCallback  ← マイクから声を受取（AEC 済み）
  AEC  ←── Bus 0 の出力を参照信号として利用
```

#### StreamFormat の設定

Bus 0 と Bus 1 でそれぞれ適切な Scope に設定する。

```swift
// Bus 0, Input Scope = アプリが書き込む側（BGM→スピーカー方向）
AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                     kAudioUnitScope_Input, 0, &asbd, size)

// Bus 1, Output Scope = アプリが読み出す側（マイク→アプリ方向）
AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                     kAudioUnitScope_Output, 1, &asbd, size)
```

### 2. 採点アルゴリズム

#### セント誤差 → 点数の変換

```
|cents| < 25  : 100 点（ほぼ正確）
|cents| 25〜75 : 100 → 0 点に線形減少
|cents| ≥ 75  : 0 点
```

```swift
private func pitchScore(centsError: Double) -> Double {
    if centsError < 25  { return 100 }
    if centsError < 75  { return max(0, 100 - (centsError - 25) * 2) }
    return 0
}
```

セント誤差は検出周波数と基準周波数の対数比で計算する（Step 6 で学んだ公式）。

```swift
let centsError = abs(1200.0 * log2(detectedHz / referenceHz))
```

#### 同一ノートの最高点採用

同じノートに対して複数回採点結果が届く（ポーリング間隔 × ノート長の分だけ）。
各ノートに対して**最高スコアのみを保持**することで、「一瞬でも正しく歌えたら点数になる」仕様にしている。

```swift
if score > noteScores[existingIndex].score {
    noteScores[existingIndex] = noteScore  // 最高点で上書き
}
```

### 3. BGM周波数のリアルタイム更新

期待ノートが変わるたびに BGM 周波数をコールバックに伝える。
Step 4 の SPSC Queue パターンで UI スレッド → オーディオスレッドに安全に渡す。

```swift
// UI スレッド（30fps ポーリング）
if currentExpectedNote?.noteName != prevNote?.noteName {
    engine.setBGMFrequency(currentExpectedNote?.frequency ?? 0)
}

// KaraokeEngine 内部
func setBGMFrequency(_ hz: Double) {
    _ = context.bgmCommandQueue.enqueue(hz)  // LockFreeQueue に積む
}

// BGM コールバック冒頭（オーディオスレッド）
while let newFreq = ctx.bgmCommandQueue.dequeue() {
    ctx.bgmFrequency = newFreq
}
```

### 4. オクターブトランスポーズ

歌う人の声域に合わせてメロディを1オクターブ単位でシフトできる。

```
frequency × 2^n で周波数を変換
n = +1 → 1オクターブ上（×2）
n = -1 → 1オクターブ下（÷2）
```

```swift
func transposed(byOctaves n: Int) -> NoteEvent {
    let newFrequency = frequency * pow(2.0, Double(n))
    let newNoteName  = shiftOctaveInName(noteName, by: n)
    return NoteEvent(...)
}
```

音名の末尾にある数字（オクターブ番号）を ±n するだけで音名も更新できる。

### 5. AudioConverter API

C API でのフォーマット変換。入出力フォーマットが異なる場合、内部でリサンプリングが自動実行される。

```swift
// Step 1: 変換前後のフォーマットを定義
var inputASBD  = AudioStreamBasicDescription(...)  // Float32 / 48000 Hz
var outputASBD = AudioStreamBasicDescription(...)  // Int16   / 44100 Hz

// Step 2: コンバーターを生成
var converter: AudioConverterRef?
AudioConverterNew(&inputASBD, &outputASBD, &converter)

// Step 3: 変換実行
AudioConverterConvertBuffer(converter, inputSize, inputPtr, &outputSize, outputPtr)

// Step 4: 後始末
AudioConverterDispose(converter)
```

#### 主なユースケース

| 変換 | 用途 |
|---|---|
| Float32 → Int16 | ファイル保存（WAV / PCM）|
| 48000 Hz → 44100 Hz | 異なるサンプルレートのデバイスへ送信 |
| モノラル → ステレオ | ミックスダウン前の準備 |
| PCM → AAC | 低帯域通信向け圧縮 |

#### `withUnsafeBytes` での安全なポインタ取得

```swift
// baseAddress は Optional なので guard let で安全にアンラップ
let status: OSStatus = samples.withUnsafeBytes { inPtr in
    output.withUnsafeMutableBytes { outPtr in
        guard let inBase = inPtr.baseAddress,
              let outBase = outPtr.baseAddress else {
            return kAudio_ParamError
        }
        return AudioConverterConvertBuffer(converter, inputSize, inBase, &outputSize, outBase)
    }
}
```

`!` で強制アンラップすると配列が空のときにクラッシュする。
`guard let` で `nil` のときは `kAudio_ParamError` を返して安全に処理する。

---

## 確認手順（アプリでの操作）

### 確認1: オクターブシフトと BGM

1. オクターブを自分の声域に合わせて設定
2. 「歌い始める」をタップ → BGM がスピーカーから鳴る
3. BGM に合わせて歌い、音符ごとのスコアを確認

### 確認2: AEC の効果

イヤホンなしで BGM を鳴らしながら歌ったとき、BGM がマイクに入っても採点に影響しないことを確認する。VPIO の AEC が BGM を参照信号として除去しているため。

### 確認3: AudioConverter デモ

「AudioConverter デモを実行」をタップし、出力サンプル数が `入力サンプル数 × (44100 / sampleRate)` になっていることを確認する。

---

## AVAudioEngine との対応

```swift
// AVAudioEngine でカラオケ的な構成を作る場合
try engine.setVoiceProcessingEnabled(true)  // 内部の I/O ユニットを VPIO に切り替え（AEC有効）

// BGM のリアルタイム生成には AVAudioSourceNode（iOS 13+）を使う
// AVAudioSourceNode はレンダーコールバックを持つため、BGM RenderCallback に相当する
let sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList in
    // ここにサイン波生成ロジックを書く（KaraokeEngine の BGM RenderCallback と同等）
    return noErr
}
engine.attach(sourceNode)
engine.connect(sourceNode, to: engine.mainMixerNode, format: nil)

// マイク入力のタップ（InputCallback + AudioUnitRender に相当）
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
    // ここでピッチ検出を行う
}
```

> **注意**:  
> `AVAudioPlayerNode` はファイルやバッファを再生するためのノードであり、サイン波のようなリアルタイム波形生成はできない。  
> リアルタイム生成が必要な場合は `AVAudioSourceNode` を使う。  
> AEC は `setVoiceProcessingEnabled(true)` によって有効になり、`sourceNode` → `mainMixerNode` → `outputNode` を通じてスピーカーへ出力された音声を参照信号として `inputNode` のマイク入力から自動除去する。

---

## 次のステップへの問い

1. BGM がスピーカーから出ているのに採点に影響しない理由を、AEC の仕組みから説明できるか？
2. `AudioConverterConvertBuffer` でリサンプリングが自動実行される仕組みは何か？ なぜ入出力サンプル数が異なるか？
3. `@Observable` の `didSet` で同じプロパティに再代入するとなぜスタックオーバーフローになるか？

これらに答えられたら **Step 8: AudioUnit Extension（C API 最深部）** へ進む。
