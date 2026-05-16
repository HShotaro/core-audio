# Step 1: C API で Audio Unit を直接操作する

## 学習目標

`AVAudioEngine` が隠蔽している Audio Unit の生成・接続・プロパティ取得を、C API を直接使って再現する。
「AVFoundation がやってくれていたこと」を1つずつ自分の手で確認できるようになる。

---

## C API の基本フロー

```
AudioComponentFindNext(nil, &desc)   // 条件に合うコンポーネントを検索
        ↓
AudioComponentInstanceNew(comp, &au) // インスタンス生成（メモリ確保）
        ↓
AudioUnitInitialize(au)              // 初期化（ハードウェアリソース確保）
        ↓
AudioUnitGetProperty / SetProperty   // プロパティの読み書き
        ↓
AudioUnitUninitialize(au)            // リソース解放
AudioComponentInstanceDispose(au)    // インスタンス破棄
```

AVAudioEngine の各操作との対応：

| AVAudioEngine | C API | 補足 |
|---|---|---|
| `attach()` / `connect()` | `AudioComponentInstanceNew` | インスタンス生成 |
| `connect(_:to:format:)` | `AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)` + `AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback)` | フォーマット交渉＋プル連鎖の構築 |
| `prepare()` | `AudioUnitInitialize` | I/O開始なし。リソースだけ事前確保 |
| `start()` | `AudioUnitInitialize` + `AudioOutputUnitStart` | prepare済みなら `AudioOutputUnitStart` のみ |
| `pause()` | `AudioOutputUnitStop` | `AudioUnitUninitialize` は呼ばない。バッファ・接続は保持 |
| `stop()` | `AudioOutputUnitStop` + `AudioUnitUninitialize` | リソースまで解放 |
| `reset()` | `AudioUnitReset(au, kAudioUnitScope_Global, 0)` | 内部バッファをクリア。接続・初期化は維持 |

**`AudioOutputUnitStart`** は `AudioUnitInitialize` とは別の API で、RemoteIO に「オーディオI/Oコールバックを開始せよ」と伝える命令。これが呼ばれて初めてマイク・スピーカーとのデータのやり取りが始まる。

**`pause()` と `stop()` の違い**: `pause()` は `AudioUnitUninitialize` を呼ばないためリソースが保持されたまま。再開が `AudioOutputUnitStart` 1回で済む理由がこれ。

**`reset()` の用途**: リバーブの残響やディレイのバッファなど AU 内部の状態をクリアしたいが、接続や初期化は維持したい場合に使う。

#### connect() のバリアントと Bus 番号

```swift
// Bus 0 → Bus 0 に固定接続（シンプルな1対1）
connect(playerNode, to: mixerNode, format: format)

// Bus番号を明示指定（複数入力をMixerの別Busに割り当てる場合）
connect(playerNode,  to: mixerNode, fromBus: 0, toBus: 0, format: format)
connect(bgmNode,     to: mixerNode, fromBus: 0, toBus: 1, format: format)
```

`connect(_:to:format:)` は常に Bus 0→0 の固定接続。MixerNode に複数の音声を別々のバスで入力したい場合（例: ボーカルと BGM を独立してボリューム制御したい）は `fromBus:toBus:` で Bus 番号を明示する必要がある。

> **Note**: AU 同士の「接続」（`AVAudioEngine.connect(_:to:)` の内部）は、C API では `AUGraph` または `kAudioUnitProperty_SetRenderCallback` を使って実現する。これは Step 3 で扱う。Step 1 のスコープは AU の**発見・生成・プロパティ読み取り**まで。

---

## 学べること

### 1. AudioComponentDescription — AU の「型情報」

Audio Unit の種別は `componentType` + `componentSubType` の FourCC 2つで識別される。

```swift
var desc = AudioComponentDescription(
    componentType:         kAudioUnitType_Output,      // "auou"
    componentSubType:      kAudioUnitSubType_RemoteIO, // "rioc"
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags:        0,
    componentFlagsMask:    0
)
let comp = AudioComponentFindNext(nil, &desc)
```

| componentType | componentSubType | 意味 | AVAudioEngine での対応 |
|---|---|---|---|
| `auou` | `rioc` | RemoteIO | outputNode / inputNode |
| `aumx` | `mcmx` | MultiChannelMixer | mainMixerNode |
| `augn` | `acpn` | ScheduledSoundPlayer | AVAudioPlayerNode |

### 2. AudioComponentInstanceNew — インスタンス生成

```swift
var au: AudioUnit?
AudioComponentInstanceNew(comp, &au) // AU インスタンスを生成
AudioUnitInitialize(au!)             // ハードウェアリソースを確保
```

- `AudioComponentInstanceNew` はメモリ確保のみ。この時点ではハードウェアと未接続
- `AudioUnitInitialize` で初めてハードウェアリソース（マイク・スピーカー等）が確保される
- `AVAudioEngine.start()` は内部でこの2ステップを実行している
- AU 同士をどう接続するかは別の仕組み（`AUGraph` / `RenderCallback`）が必要で、Step 3 で扱う

### 3. RemoteIO のバス構造

RemoteIO は **1つのインスタンスで入力と出力の両方**を担う。`AVAudioEngine` の `inputNode` と `outputNode` が同一の RemoteIO を指している理由がこれ。

```
【アプリ側】                  RemoteIO AU                【ハードウェア側】

  音声データを書き込む  →  Bus 0, kAudioUnitScope_Input  →  スピーカー
  （AUへの入力）

  音声データを読み取る  ←  Bus 1, kAudioUnitScope_Output ←  マイク
  （AUからの出力）
```

#### Scope の命名は「AU 自身から見た視点」

混乱しやすいのが「アプリが音を出す（Output）なのになぜ `kAudioUnitScope_Input`？」という点。
Scope の名前は**アプリ視点ではなく、AU 自身から見た視点**で決まる。

| Scope | 意味 |
|---|---|
| `kAudioUnitScope_Input` | AU に**入ってくる**データの口 |
| `kAudioUnitScope_Output` | AU から**出ていく**データの口 |

- Bus 0 はアプリが音声データを RemoteIO に**送り込む**（= AU への Input）→ `kAudioUnitScope_Input`
- Bus 1 はアプリが RemoteIO からマイク音声を**受け取る**（= AU からの Output）→ `kAudioUnitScope_Output`

`AudioUnitGetProperty` / `AudioUnitSetProperty` で Scope を指定するときは常に「AU 自身から見てどちら向きか」を意識する。

Bus 1（マイク入力）はデフォルトで無効。明示的に有効化が必要。

```swift
var enable: UInt32 = 1
AudioUnitSetProperty(
    au,
    kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Input,
    1, // Bus 1
    &enable,
    UInt32(MemoryLayout<UInt32>.size)
)
```

VPIO でマイク入力を有効化するときに Bus 指定が必要な理由も同じ構造による。

### 4. AudioUnitGetProperty — プロパティの読み取り

```swift
// サンプルレートを読む
var sampleRate: Float64 = 0
var size = UInt32(MemoryLayout<Float64>.size)
AudioUnitGetProperty(
    au,
    kAudioUnitProperty_SampleRate,
    kAudioUnitScope_Output,
    0,      // bus番号
    &sampleRate,
    &size
)
```

全プロパティは `<AudioToolbox/AudioUnit.h>` に定義されている。AVFoundation はこのAPIを内部で呼び出し、Swiftフレンドリーなインターフェースに包んでいるだけ。

### 5. AudioStreamBasicDescription (ASBD) — フォーマットの完全な記述

`AVAudioFormat` が内部で持つフォーマット情報の実体。

```swift
var asbd = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioUnitGetProperty(
    au,
    kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Input,
    0,
    &asbd,
    &size
)
```

| フィールド | 典型値 | 意味 |
|---|---|---|
| `mSampleRate` | 44100 / 48000 | 1秒あたりのサンプル数 |
| `mFormatID` | `lpcm` | Linear PCM（非圧縮）|
| `mFormatFlags` | `Float \| NonInterleaved` | 32bit浮動小数、チャンネル別バッファ |
| `mBitsPerChannel` | 32 | 1サンプルのビット数 |
| `mChannelsPerFrame` | 2 | ステレオ |
| `mBytesPerFrame` | 4 | 1フレームのバイト数（= 32bit / 8）|
| `mFramesPerPacket` | 1 | PCM は常に1 |
| `mBytesPerPacket` | 4 | PCM は mBytesPerFrame と同値 |

#### NonInterleaved とは

**Interleaved**: L R L R L R … （1バッファにLとRが交互）  
**NonInterleaved**: L L L … / R R R … （LとRが別バッファ）

RemoteIO はデフォルト NonInterleaved。`AudioBufferList.mNumberBuffers` がステレオ時に `2` になる理由がこれ。

---

## 確認手順（アプリでの操作）

### 確認1: RemoteIO の componentSubType

ボタンをタップ後、RemoteIO セクションを確認する。

**確認すること**
- `componentType` が `auou` であること
- `componentSubType` が `rioc` であること

**なぜ重要か**  
この FourCC が分かると、Apple ドキュメントや `AudioUnit.h` で RemoteIO の全仕様を調べられるようになる。

---

### 確認2: RemoteIO のバス構造（ASBD）

Bus 0 と Bus 1 のセクションを比較する。

**確認すること**
- Bus 0（Output）の ASBD が読めること
- Bus 1（Input）の ASBD が読めること（Bus 1 有効化が必要なため、有効化なしでは nil になる）
- `mFormatFlags` に `Float` と `NonInterleaved` が含まれること
- `mBytesPerFrame` が `4`（= 32bit float）であること

**なぜ重要か**  
AVAudioEngine の `outputNode` と `inputNode` が同一 RemoteIO の別バスを指していることが、
バスのポインタ・ASBDを読むことで実感できる。

---

### 確認3: MultiChannelMixer の AU情報

Mixer セクションを確認する。

**確認すること**
- `componentType` が `aumx` であること
- `componentSubType` が `mcmx` であること

**なぜ重要か**  
`AVAudioEngine.mainMixerNode` の正体が MultiChannelMixer であることが確認でき、
`connect(_:to:)` がこの AU のバスに接続していることが理解できる。

---

## AVAudioEngine との対応まとめ

| AVAudioNode | C API で作るAU | componentSubType |
|---|---|---|
| `outputNode` | RemoteIO, Bus 0, Input Scope | `rioc` |
| `inputNode` | RemoteIO, Bus 1, Output Scope | `rioc` |
| `mainMixerNode` | MultiChannelMixer | `mcmx` |
| `AVAudioPlayerNode` | ScheduledSoundPlayer | `acpn` |

---

## 次のステップへの問い

Step 1 を終えたら以下を自分の言葉で説明できるか確認する。

1. `AudioComponentInstanceNew` と `AudioUnitInitialize` はそれぞれ何をしているか？ なぜ2段階に分かれているか？
2. RemoteIO の Bus 0 と Bus 1 の違いは何か？ Scope（Input/Output）の意味は何か？
3. `mFormatFlags` の `NonInterleaved` フラグが立っているとき、ステレオの `AudioBufferList` はどんなメモリ構造になるか？

これらに答えられたら **Step 2: VPIO の中身を理解する** へ進む。
