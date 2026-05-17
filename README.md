# Core Audio 学習プロジェクト

iOS の Core Audio を C API レベルから理解するための学習プロジェクト。
AVAudioEngine / VPIO の実装経験をベースに、ブラックボックス化された概念を1つずつ紐解く。

---

## 学習ステップ

### Step 1: C API で Audio Unit を直接操作する
**詳細**: [Step1_Learning_Guide.md](Step1_Learning_Guide.md)

AVAudioEngine が隠蔽している Audio Unit の生成・プロパティ取得を C API で再現する。

| 学習内容 | 概要 |
|---|---|
| AudioComponentDescription | AU の型情報（FourCC）で種別を識別する |
| AudioComponentInstanceNew | インスタンス生成とハードウェアリソース確保の2段階フロー |
| RemoteIO のバス構造 | Bus 0=Output / Bus 1=Input と Scope の命名規則（AU 自身視点）|
| AudioUnitGetProperty | サンプルレート・ASBD をC APIで直接読む |
| ASBD | AVAudioFormat が内部で持つフォーマットの完全な記述 |
| AVAudioEngine との対応 | attach/connect/prepare/start/pause/stop/reset の C API マッピング |

**AVAudioEngine ノードと Audio Unit の対応**

| AVAudioNode | componentSubType | バス構造 |
|---|---|---|
| outputNode | `rioc` (RemoteIO) | Bus 0, kAudioUnitScope_Input |
| inputNode | `rioc` (RemoteIO) | Bus 1, kAudioUnitScope_Output |
| mainMixerNode | `mcmx` (MultiChannelMixer) | Input Bus が複数、Output Bus は1つ |
| AVAudioPlayerNode | `acpn` (ScheduledSoundPlayer) | — |

---

### Step 2: VPIO の内側を理解する
**詳細**: [Step2_Learning_Guide.md](Step2_Learning_Guide.md)

`kAudioUnitSubType_VoiceProcessingIO` の正体を C API で確認し、AEC / AGC / VAD の原理を理解する。

| 学習内容 | 概要 |
|---|---|
| VPIO と RemoteIO の違い | componentSubType が `vpio` になるだけ。バス構造は同一 |
| AEC の原理 | Bus 0 出力を参照信号として Bus 1 マイク入力からエコーを除去 |
| AGC の仕組み | RMS 測定 → 目標値との比較 → Attack/Release でゲイン更新 |
| VAD | 音声区間検出。AGC・AEC と連動して無音区間の処理を最適化 |
| C API でプロパティ制御 | `kAUVoiceIOProperty_*` で AEC/AGC を個別に ON/OFF |
| Global Scope | バスに依存しない AU 全体の動作モード設定に使う Scope |
| バッファサイズとレイテンシ | サンプル数 / サンプルレート × 1000 = レイテンシ（ms）|
| VPIO のコスト | AEC の処理段数分レイテンシが積み重なり 40ms 以上になる |

**VPIO 固有プロパティ**

| プロパティ | 意味 | デフォルト |
|---|---|---|
| `kAUVoiceIOProperty_BypassVoiceProcessing` | AEC・AGC・VAD をまとめて ON/OFF（上位スイッチ）| 0（有効）|
| `kAUVoiceIOProperty_VoiceProcessingEnableAGC` | AGC のみ個別制御 | 1（有効）|
| `kAUVoiceIOProperty_MuteOutput` | 出力ミュート | 0（ミュートなし）|

---

### Step 3: RenderCallback で音を鳴らす
**詳細**: [Step3_Learning_Guide.md](Step3_Learning_Guide.md)

`AVAudioEngine.connect(_:to:)` が内部で設定している RenderCallback の仕組みを理解する。
RemoteIO + RenderCallback だけでサイン波を出力し、プルモデルを体感する。

| 学習内容 | 概要 |
|---|---|
| プルモデル | ハードウェア側が主導してコールバックを呼び出す設計 |
| AURenderCallbackStruct | `connect()` が内部でやっていることを C API で再現 |
| inRefCon によるコンテキスト受け渡し | `Unmanaged` を使った void* ↔ Swift オブジェクト変換 |
| AudioBufferList の操作 | NonInterleaved バッファへのサンプル書き込み |
| サイン波の生成 | 位相・周波数・サンプルレートの関係 |
| リアルタイムスレッドの制約入門 | コールバック内の禁止操作と理由 |

---

### Step 4: リアルタイムスレッドの制約を理解する
**詳細**: [Step4_Learning_Guide.md](Step4_Learning_Guide.md)

Priority Inversion の仕組みを理解し、UI スレッドとオーディオスレッド間のデータ受け渡しを SPSC Ring Buffer で安全に実装する。

| 学習内容 | 概要 |
|---|---|
| Priority Inversion | malloc がリアルタイムスレッドを止めるメカニズム |
| Step 3 の問題点 | UI スレッドからの直接書き換えによるデータ競合 |
| SPSC Ring Buffer | Producer/Consumer が別インデックスを更新することでロック不要になる原理 |
| コマンドパターン | パラメータ変更を Queue に積んでコールバック冒頭で処理する設計 |
| 禁止操作まとめ | malloc / ObjC / lock / ファイルI/O / ARC の代替手段 |

**Step 3 との比較**

| | Step 3 | Step 4 |
|---|---|---|
| 周波数変更 | `ctx.frequency = newValue`（直接・データ競合の可能性）| `queue.enqueue(.setFrequency(hz))`（SPSC 経由・安全）|
| コールバック内処理 | サンプル生成のみ | コマンド処理 → サンプル生成 |

---

### Step 5: DSP 基礎（FFT・フィルター）
**詳細**: [Step5_Learning_Guide.md](Step5_Learning_Guide.md)

Accelerate フレームワークの `vDSP` を使いスペクトル解析とフィルター設計を実装する。
FFT でカラオケのピッチ検出の原理を理解し、IIR・Biquad フィルターの違いを体感する。

| 学習内容 | 概要 |
|---|---|
| FFT | 時間領域→周波数領域変換・vDSP 5ステップ・Hanning ウィンドウ |
| FFT サイズと分解能 | 周波数分解能・時間分解能のトレードオフ・不確定性原理 |
| installTap とバッファサイズ | 要求値と実際のサイズの違い・オーバーラップ処理 |
| 一次 IIR LPF | y[n] = α×x[n] + (1-α)×y[n-1]・-20 dB/decade |
| Biquad LPF | 二次バターワース・vDSP_biquad・-40 dB/decade |
| フィルター比較 | 次数・ロールオフ・カスケードによる高次化 |
| カラオケへの応用 | FFT スパイク位置から基本周波数を特定するピッチ検出の原理 |

**フィルター比較**

| | 一次 IIR | Biquad（二次）|
|---|---|---|
| ロールオフ | -20 dB/decade | -40 dB/decade |
| 係数 | α（1個）| b0,b1,b2,a1,a2（5個）|
| 実装 | 手動ループ | `vDSP_biquad` |

---

### Step 6: リアルタイムピッチ検出
*coming soon*

Step 5 の FFT をベースに、マイク入力からリアルタイムで音の高さを検出する。
カラオケ採点の核心となる「今歌っている音が何の音か」を C API + DSP で実装する。

| 学習内容 | 概要 |
|---|---|
| HPS法（Harmonic Product Spectrum）| 倍音構造を利用した基本周波数推定 |
| 自己相関法 | 波形の周期性を直接検出するアプローチ |
| Hz → 音名変換 | A4=440 Hz を基準にした MIDI ノート番号・音名の計算 |
| C API + DSP の融合 | VPIO のレンダーコールバック内で vDSP を使ったリアルタイム処理 |

```
マイク → VPIO → FFT → HPS → 基本周波数（Hz） → 音名（ド・レ・ミ…）
```

---

### Step 7: 採点エンジン
*coming soon*

Step 6 のピッチ検出を使い、基準音との比較からリアルタイムにスコアを算出する。
AudioConverter API（C API）でマイク入力のフォーマット変換も実装する。

| 学習内容 | 概要 |
|---|---|
| AudioConverter API | C API でのフォーマット変換・リサンプリング |
| 基準音との比較 | MIDI / 音符データと検出ピッチの差分計算 |
| ピッチ精度スコア | セント（cent）単位での誤差計算（1セント = 1/100半音）|
| タイミング精度スコア | 発声タイミングと音符の開始・終了との一致度 |
| 総合スコア計算 | ピッチ精度 × タイミング精度の重み付けスコア |

---

### Step 8: AudioUnit Extension（C API 最深部）
*coming soon*

iOS のカスタムエフェクトプラグインを C API で実装する。
他のアプリからも利用できる AU プラグインとして仕上げる。

| 学習内容 | 概要 |
|---|---|
| AudioUnit Extension | `kAudioUnitType_Effect` でカスタム AU を実装 |
| ピッチシフト | Phase Vocoder を使ったリアルタイムピッチ変換 |
| リバーブ | 畳み込みリバーブ（Convolution Reverb）の実装 |
| App Extension | 他のアプリから AU プラグインとして利用できる形に仕上げる |

---

## プロジェクト構成

```
core-audio/
├── CoreAudioStudy/               # Xcode プロジェクト
│   └── CoreAudioStudy/
│       ├── Step1/
│       │   ├── AudioUnitInspector.swift   # C APIロジック
│       │   ├── Step1ViewModel.swift
│       │   └── Step1View.swift
│       ├── Step2/
│       │   ├── VPIOInspector.swift        # VPIO C APIロジック
│       │   ├── Step2ViewModel.swift
│       │   └── Step2View.swift
│       ├── Step3/
│       │   ├── RenderCallbackEngine.swift # RemoteIO + RenderCallback
│       │   ├── Step3ViewModel.swift
│       │   └── Step3View.swift
│       ├── Step4/
│       │   ├── LockFreeQueue.swift        # SPSC Ring Buffer
│       │   ├── SafeRenderEngine.swift     # スレッドセーフなエンジン
│       │   ├── Step4ViewModel.swift
│       │   └── Step4View.swift
│       └── Step5/
│           ├── FFTAnalyzer.swift          # vDSP FFT 解析
│           ├── BiquadLPFilter.swift       # vDSP_biquad ローパスフィルター
│           ├── Step5Engine.swift          # AVAudioEngine + installTap
│           ├── Step5ViewModel.swift
│           └── Step5View.swift            # スペクトル可視化
├── Step1_Learning_Guide.md
├── Step2_Learning_Guide.md
├── Step3_Learning_Guide.md
├── Step4_Learning_Guide.md
├── Step5_Learning_Guide.md
└── README.md
```

## 動作環境

- iOS 14.0+
- Xcode 15+
- Step 2 の VPIO は**実機推奨**（シミュレータではインスタンス生成が失敗する場合あり）
