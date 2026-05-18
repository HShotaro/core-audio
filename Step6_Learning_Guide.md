# Step 6: リアルタイムピッチ検出

## 学習目標

VPIO の InputCallback を使ってマイク入力をキャプチャし、FFT + HPS でリアルタイムにピッチを検出する。
Step 1〜5 で学んだ知識（VPIO・RenderCallback・SPSC Queue・FFT）が実際のアプリ機能として統合される。

---

## Step 1〜5 の知識の統合

```
マイク
  ↓
VPIO（Step 2: C APIで生成）
  ↓ InputCallback（Step 3: RenderCallbackの対称版）
AudioUnitRender でデータを取り出す
  ↓
サンプル蓄積バッファ
  ↓ FFT + HPS（Step 5: vDSP）
PitchResult
  ↓ SPSC Queue（Step 4: LockFreeQueue）
UI スレッド → チューナー表示
```

---

## 学べること

### 1. InputCallback と RenderCallback の違い

Step 3 で学んだ RenderCallback との対称関係を理解する。

| | RenderCallback | InputCallback |
|---|---|---|
| プロパティ | `kAudioUnitProperty_SetRenderCallback` | `kAudioOutputUnitProperty_SetInputCallback` |
| 呼ばれるタイミング | AU が「データをくれ」と要求するとき | AU が「データが届いた」と通知するとき |
| `ioData` | バッファが渡される（書き込む） | `nil`（自分で取り出す）|
| データ取得方法 | `ioData` に直接書き込む | コールバック内で `AudioUnitRender` を呼ぶ |
| Scope | `kAudioUnitScope_Input` | `kAudioUnitScope_Global` |

#### InputCallback 内での AudioUnitRender

InputCallback の `ioData` は `nil` のため、自分で `AudioBufferList` を用意して `AudioUnitRender` を呼ぶ必要がある。

```swift
let inputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let ctx = Unmanaged<PitchContext>.fromOpaque(inRefCon).takeUnretainedValue()

    // スタック上に AudioBufferList を構築（malloc なし）
    var buffer = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize:   inNumberFrames * 4,
        mData:           ctx.inputBuffer   // 事前確保バッファ
    )
    var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)

    // VPIO Bus 1 からマイクデータをプル
    AudioUnitRender(ctx.vpio!, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    
    // ctx.inputBuffer にマイクデータが入っている
}
```

### 2. VPIO の入力専用セットアップ

ピッチ検出ではマイク音をスピーカーに出す必要がない。Bus 0（出力）を無効化する。

```swift
var enable:  UInt32 = 1
var disable: UInt32 = 0

// Bus 1 (Input) を有効化
AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                     kAudioUnitScope_Input, 1, &enable, size)

// Bus 0 (Output) を無効化（マイク音がスピーカーから出ないように）
AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                     kAudioUnitScope_Output, 0, &disable, size)
```

Bus 1 の StreamFormat は `kAudioUnitScope_Output` に設定する。

```
マイク → [VPIO AU の Bus 1] → アプリ
                 ↑
         Bus 1 の中を流れるデータには「AU に入ってくる側」と「AU から出ていく側」がある

         kAudioUnitScope_Input  (Bus 1) = ハードウェアからAUに入ってくる側（マイク→AU）
         kAudioUnitScope_Output (Bus 1) = AU からアプリへ出ていく側（AU→アプリ）
                                          ↑ ここのフォーマットを設定する
```

`AudioUnitRender` でアプリがデータを「受け取る口」は Bus 1 の Output Scope 側。
そのため StreamFormat の設定も `kAudioUnitScope_Output, bus 1` に対して行う。

> **注意: Scope の意味はプロパティによって文脈が異なる**
>
> `kAudioOutputUnitProperty_EnableIO` における Scope は「どちらのハードウェア側か」を指す:
> - `kAudioUnitScope_Input, bus 1` → マイクのハードウェアを有効/無効
> - `kAudioUnitScope_Output, bus 0` → スピーカーのハードウェアを有効/無効
>
> `kAudioUnitProperty_StreamFormat` における Scope は「AU 自身から見た方向」を指す:
> - `kAudioUnitScope_Output, bus 1` → AU からアプリへ出るデータのフォーマット
>
> 同じ `kAudioUnitScope_Output` でも、プロパティが違えば意味が変わる。

### 3. HPS（Harmonic Product Spectrum）

#### なぜ単純な FFT ピーク検出では不十分か

楽器や声の音には**倍音**が含まれる。440 Hz の音は 880 Hz・1320 Hz にもスパイクが立つ。
単純に FFT の最大ピークを探すと、倍音を基本周波数と誤認することがある。

```
440 Hz の声の FFT:
  bin: 19(440Hz)  bin: 37(880Hz)  bin: 56(1320Hz)
    ↑↑                ↑                ↑
  (基本)            (倍音)            (倍音)

880 Hz の倍音が 440 Hz より大きいと → 誤って 880 Hz と判定してしまう
```

#### HPS の仕組み

スペクトルと、それを 2・3 倍に間引いたコピーを掛け合わせる。
倍音は移動するが、基本周波数は常に同じ位置に残るため強調される。

```
元スペクトル (÷1):  spike @ f0, 2f0, 3f0
÷2 で圧縮:          spike @ f0(←2f0), 1.5f0(←3f0)
÷3 で圧縮:          spike @ f0(←3f0)

3つの積: f0 のスパイクは 3 回掛け合わされて強調
         他の位置は揃わないため小さくなる
```

#### HPS の計算式（具体例）

FFT サイズ 4096・サンプルレート 48000 Hz のとき：
- bin 幅 = 48000 / 4096 ≈ 11.7 Hz/bin
- 440 Hz ≒ bin 37、880 Hz ≒ bin 75、1320 Hz ≒ bin 113

**harmonics = 3 のとき、各 bin の product:**

$$\text{product}[i] = \text{spectrum}[i] \times \text{spectrum}[i \times 2] \times \text{spectrum}[i \times 3]$$

| bin | 計算 | 結果 |
|---|---|---|
| bin 37（440 Hz）| spectrum[37] × spectrum[74] × spectrum[111] | **大 × 大 × 大 = 最大** |
| bin 75（880 Hz）| spectrum[75] × spectrum[150] × spectrum[225] | 大 × 小 × 小 = 小 |
| bin 113（1320 Hz）| spectrum[113] × spectrum[226] × spectrum[339] | 大 × 小 × 小 = 小 |

- **bin 37（基本周波数 f0）**: 440 Hz・880 Hz・1320 Hz の3つが全てスパイクを持つためかけ算の結果が大きくなる
- **bin 75（倍音 2f0）**: 880 Hz はスパイクだが 1760 Hz・2640 Hz にはスパイクがないため積は小さい

これが「基本周波数だけが強調される」仕組み。

```swift
static func hps(spectrum: [Float], harmonics: Int) -> Int {
    let validCount = spectrum.count / harmonics
    var product = Array(spectrum.prefix(validCount))

    for h in 2...harmonics {
        for i in 0..<validCount {
            // product[i] = spectrum[i] × spectrum[i×2] × spectrum[i×3]
            product[i] *= spectrum[i * h]
        }
    }
    // product の最大値の位置が基本周波数の bin
    return product[minBin...maxBin].enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
}
```

### 4. Hz → 音名 + セント偏差

#### MIDI ノート番号

A4（440 Hz）を基準に、12 音平均律で音名を算出する。

```
MIDI ノート番号 = 12 × log2(f / 440) + 69

例: 523.25 Hz (C5)
  = 12 × log2(523.25 / 440) + 69
  = 12 × 0.25 + 69
  = 72 → C5
```

#### セント偏差

1 オクターブ = 1200 cents、1 半音 = 100 cents。
最近傍の音名からのズレを cents で表す。

```
cents = 1200 × log2(検出周波数 / 基準周波数)

例: 445 Hz（A4 より少し高い）
  基準: 440 Hz
  cents = 1200 × log2(445/440) ≈ +19.6 cents
```

| セント偏差 | 評価 |
|---|---|
| ±10 cents 以内 | ほぼ正確 |
| ±25 cents 以内 | やや外れ |
| ±25 cents 超 | 大きくズレている |

### 5. サンプル蓄積バッファ

InputCallback は毎回 256〜1024 サンプル程度しか届けない。
FFT サイズ（4096 サンプル）分を貯めるため循環バッファで蓄積する。

```
コールバック 1回目: [s0  s1  ...  s511 ] → accumulator[0..511]
コールバック 2回目: [s512 ...   s1023] → accumulator[512..1023]
...
コールバック 8回目: [s3584... s4095] → accumulator[3584..4095]
                                        ↓ fftSize(4096) 分揃った
                                        FFT + HPS 実行 → PitchResult
                                        バッファリセット
```

4096 samples / 48000 Hz ≈ **85ms ごとにピッチ検出**が実行される。

---

## 実装上の注意点（プロダクション環境向け）

| 問題 | 本実装（教育用）| プロダクション環境 |
|---|---|---|
| コールバック内での Array 生成 | あり（malloc 発生）| 事前確保バッファを使用 |
| FFT を同スレッドで実行 | あり | 専用 background queue に dispatch |
| SPSC Queue から UI への反映 | Timer で 30fps ポーリング | 同様（許容範囲）|

---

## 確認手順（アプリでの操作）

### 確認1: 音名の検出精度

「検出開始」後、440 Hz の基準音（チューナーアプリや楽器）をマイクに向け、`A4` と表示されることを確認する。

---

### 確認2: チューナー針の動き

正確な音を出すと針が中央（0 cents）付近に、ズレた音では左右に動くことを確認する。

---

### 確認3: HPS の効果

低い音（100〜200 Hz）を出したとき、FFT の最大ピーク位置（倍音）ではなく、基本周波数が正しく検出されることを確認する。

---

## AVAudioEngine との対応

```swift
// AVAudioEngine でマイク入力を扱う場合
let inputNode = engine.inputNode
inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
    // buffer.floatChannelData でサンプルにアクセス
}
// → InputCallback + AudioUnitRender の処理を AVAudioEngine が隠蔽している
```

---

## 次のステップへの問い

1. InputCallback の `ioData` が `nil` である理由は何か？ RenderCallback と比較して説明できるか？
2. HPS で `harmonics = 3` のとき、最大で何 Hz の基本周波数まで検出できるか？（FFT サイズ 4096、サンプルレート 48000 Hz の場合）
3. セント偏差 +100 cents は音楽的に何を意味するか？

これらに答えられたら **Step 7: 採点エンジン** へ進む。
