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
*coming soon*

オーディオコールバック内で守るべきリアルタイムスレッドの制約と、
Lock-free Queue を使った安全なデータの受け渡しを実装する。

---

### Step 5: DSP 基礎（FFT・フィルター）
*coming soon*

Accelerate フレームワークの `vDSP` を使ったスペクトル解析とフィルター設計。
カラオケのピッチシフトがどう実装されているかを理解する。

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
│       └── Step2/
│           ├── VPIOInspector.swift        # VPIO C APIロジック
│           ├── Step2ViewModel.swift
│           └── Step2View.swift
├── Step1_Learning_Guide.md
├── Step2_Learning_Guide.md
└── README.md
```

## 動作環境

- iOS 14.0+
- Xcode 15+
- Step 2 の VPIO は**実機推奨**（シミュレータではインスタンス生成が失敗する場合あり）
