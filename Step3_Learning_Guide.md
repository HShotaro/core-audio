# Step 3: AU の接続を C API で実装する（RenderCallback）

## 学習目標

`AVAudioEngine.connect(_:to:)` が内部で設定している **RenderCallback** の仕組みを理解する。
RemoteIO + RenderCallback だけでサイン波を出力し、プルモデルを体感する。

---

## 学べること

### 1. プルモデル（Pull Model）

Core Audio の根本的な設計思想。

```
ハードウェア（スピーカー）
    ↑ 音声データを要求（プル）
RemoteIO AU
    ↑ kAudioUnitProperty_SetRenderCallback で登録したコールバックを呼ぶ
アプリ（コールバック内でバッファにサンプルを詰めて返す）
```

**ポイント**: データを「送り込む（Push）」のではなく、ハードウェア側が必要なタイミングで「引っ張る（Pull）」。
このタイミングはアプリが制御できない。

`AVAudioEngine` で複数ノードを connect するとき、内部ではこのプル連鎖が構築されている。

```
スピーカー ← RemoteIO ← (callback) ← Mixer ← (callback) ← PlayerNode
```

> **Note**: 出力側（RenderCallback）がプルモデルであることは動作から確認できる。
> 入力側（マイク）の詳細な動作モデルについては公式ドキュメントでの確認が取れていないため、本ガイドでは扱わない。

### 2. AURenderCallbackStruct の設定

AU の上流をカスタムコールバックに置き換え、アプリ自身が音声データを提供する仕組み。
`AVAudioEngine.connect(nodeA, to: nodeB)` が既存ノード同士のプル連鎖を構築するのに対し、
`AURenderCallbackStruct` は「接続先ノードの代わりにアプリが直接データを供給する」ものであり、厳密には同一ではない。

#### installTap との違い

| | `AURenderCallbackStruct` | `installTap` |
|---|---|---|
| 役割 | AU が必要とするデータを**提供する** | すでに流れているデータを**観測する** |
| `ioData` / `buffer` | コールバックが**書き込む** | ブロックが**読み取る** |
| 音声への影響 | 音声の**発生源**になる | 音声の流れを変えない |

```swift
// C関数ポインタとして渡すコールバック（キャプチャ不可）
let callback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    // ioData のバッファにサンプルを書き込んで返す
    return noErr
}

var callbackStruct = AURenderCallbackStruct(
    inputProc:       callback,
    inputProcRefCon: contextPointer  // コンテキストを void* で渡す
)

AudioUnitSetProperty(
    remoteIO,
    kAudioUnitProperty_SetRenderCallback,
    kAudioUnitScope_Input,  // RemoteIO の Input（スピーカーへ書き込む側）
    0,                      // Bus 0
    &callbackStruct,
    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
)
```

#### なぜ kAudioUnitScope_Input か

Bus 0 / `kAudioUnitScope_Input` に登録することで「RemoteIO がスピーカーへ送るデータをコールバックに要求する」対応になる。
Step 1 で学んだ通り、RemoteIO の Bus 0 Input Scope はアプリからスピーカーへの流れ。
その入力口にコールバックを設定することで「データが必要なときアプリに聞く」仕組みになる。

### 3. コンテキストの受け渡し（inRefCon）

コールバックは C 関数ポインタのため Swift のコンテキストをキャプチャできない。
コンテキストは `void*`（`UnsafeMutableRawPointer`）として `inRefCon` に渡す。

```swift
// 登録時: Swift オブジェクトを void* に変換
inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()

// コールバック内: void* から Swift オブジェクトを復元
let ctx = Unmanaged<SineWaveContext>.fromOpaque(inRefCon!).takeUnretainedValue()
```

`passUnretained` / `takeUnretainedValue` を使うのは、コールバック内での retain/release が
リアルタイムスレッドの禁止操作（Swift の ARC）を踏まないようにするため。

### 4. AudioBufferList へのアクセス

Step 1 で確認した NonInterleaved 構造を実際に扱う。

```swift
// UnsafeMutableAudioBufferListPointer でチャンネルごとにアクセス
let ablPointer = UnsafeMutableAudioBufferListPointer(ioData)
for buffer in ablPointer {
    let samples = buffer.mData!.assumingMemoryBound(to: Float32.self)
    for frame in 0..<Int(inNumberFrames) {
        samples[frame] = Float32(sin(phase))
        phase += phaseIncrement
    }
}
```

ステレオ（2ch）NonInterleaved の場合:
- `ablPointer[0]` → 左チャンネルのバッファ（L L L L ...）
- `ablPointer[1]` → 右チャンネルのバッファ（R R R R ...）

#### samples への代入がそのまま出力になる仕組み

`samples` は通常の変数ではなく、**RemoteIO が用意したバッファメモリへのポインタ**。
`samples[frame] = ...` はそのメモリアドレスに直接書き込む操作のため、
コールバックが `return noErr` した後に RemoteIO がそのバッファをスピーカーへ送出する。

```
RemoteIO がバッファ（ioData）を用意してコールバックを呼ぶ
    ↓
samples = buffer.mData.assumingMemoryBound(to: Float32.self)
    ↓ （buffer.mData と同じメモリを Float32* として解釈したポインタ）
samples[frame] = Float32(sin(phase))  ← バッファメモリに直接書き込む
    ↓
return noErr
    ↓
RemoteIO がそのバッファをスピーカーへ送出
```

プルモデルの「アプリがバッファを詰めて返す」という動作がここに現れている。
`samples` に書いた値がそのまま音として出力される。

### 5. サイン波の生成

```
y[n] = sin(phase)
phase += 2π × frequency / sampleRate

例: 440 Hz, 48000 Hz の場合
phaseIncrement = 2π × 440 / 48000 ≒ 0.0576 rad/sample
```

位相が 2π を超えたら折り返す（`truncatingRemainder(dividingBy: 2π)`）。

### 6. リアルタイムスレッドの制約（入門）

コールバックはリアルタイムスレッドで実行される。
このスレッドは **Priority Inversion** を起こしてはならない。

| 禁止操作 | 理由 | 代替手段 |
|---|---|---|
| `malloc` / `free` | ロックを伴うため | 事前にバッファを確保 |
| ObjC メッセージ送信 | ランタイムがロックを取得 | C / C++ で記述 |
| `mutex` / `os_lock` | 待機が発生しうる | Lock-free Queue（Step 4）|
| ファイルI/O | ブロッキング操作 | 事前読み込み |
| Swift クラスの retain/release | ARC が内部でロック | `Unmanaged` で制御 |

> 詳細は Step 4 で扱う。

---

## 確認手順（アプリでの操作）

### 確認1: サイン波の再生

1. 「再生」ボタンをタップ
2. イヤホンまたはスピーカーから 440Hz のサイン波が聞こえることを確認

**なぜ重要か**  
RemoteIO と RenderCallback だけで音が出る体験が、AVAudioEngine が内部でやっていることの理解に直結する。

---

### 確認2: 周波数の変更

スライダーや固定ボタン（220 / 330 / 440 / 660 / 880 Hz）で周波数を変更する。

**確認すること**
- 再生中でも即座に周波数が変わること
- `context.frequency` を変更するだけで次のコールバック呼び出しに反映されること

**なぜ重要か**  
コールバックが `inRefCon` 経由でコンテキストを参照しているため、
UI スレッドからの変更がリアルタイムスレッドに反映される仕組みの理解につながる。
（ただし本来はロックフリーな受け渡しが必要 → Step 4）

---

## AVAudioEngine との対応まとめ

| AVAudioEngine の操作 | C API での相当処理 | 補足 |
|---|---|---|
| `connect(nodeA, to: nodeB, format:)` | `kAudioUnitProperty_MakeConnection` | 既存 AU 同士のプル連鎖を構築 |
| `AURenderCallbackStruct` | `kAudioUnitProperty_SetRenderCallback` | ノードの代わりにアプリが上流になる |
| `installTap(onBus:...)` | 相当する C API なし | 流れを変えずに観測するだけ |
| `start()` | `AudioOutputUnitStart(remoteIO)` | |
| `stop()` | `AudioOutputUnitStop(remoteIO)` | |

### `connect()` の C API 表現

`AVAudioEngine.connect(nodeA, to: nodeB)` は内部で `kAudioUnitProperty_MakeConnection` を使い、
「auB がデータを必要とするとき、auA の Output Bus から引っ張る」という関係を設定する。

```swift
var connection = AudioUnitConnection(
    sourceAudioUnit:    auA,  // 上流の AU（データを提供する側）
    sourceOutputNumber: 0,    // auA の Output Bus（ほとんどの AU は Output Bus が1つなので常に 0）
    destInputNumber:    0     // auB の Input Bus（Mixer など複数入力を持つ AU では 0, 1, 2 ... と変わる）
)
AudioUnitSetProperty(
    auB,                                   // 接続先（下流）の AU
    kAudioUnitProperty_MakeConnection,
    kAudioUnitScope_Input,
    0,
    &connection,
    UInt32(MemoryLayout<AudioUnitConnection>.size)
)

// 複数ノードを Mixer に接続する場合は destInputNumber を変える
// playerAU  → Mixer Input Bus 0
// bgmAU     → Mixer Input Bus 1
// Mixer     → RemoteIO Input Bus 0
//
// playerAU ──(Out:0)──→ (In:0) Mixer
// bgmAU    ──(Out:0)──→ (In:1) Mixer
//                              Mixer ──(Out:0)──→ (In:0) RemoteIO
```

`AURenderCallbackStruct` との違い：

| | `kAudioUnitProperty_MakeConnection` | `kAudioUnitProperty_SetRenderCallback` |
|---|---|---|
| 上流の提供者 | 別の AU | アプリのコールバック |
| データの出所 | 上流 AU が自分でレンダリングする | アプリがバッファに書き込む |
| 対応する AVAudioEngine | `connect(nodeA, to: nodeB)` | （直接の対応なし）|

### AUGraph（高レベル・deprecated）

`AVAudioEngine` 自体が `AUGraph` の後継として設計された。
`AUGraph` はノードとその接続をグラフとして管理する高レベル C API。

```swift
var graph: AUGraph?
NewAUGraph(&graph)

var nodeA: AUNode = 0
var nodeB: AUNode = 0
AUGraphAddNode(graph, &descA, &nodeA)
AUGraphAddNode(graph, &descB, &nodeB)
AUGraphConnectNodeInput(graph, nodeA, 0, nodeB, 0)  // connect() 相当

AUGraphInitialize(graph)
AUGraphStart(graph)
```

```
AVAudioEngine.connect(nodeA, to: nodeB)
    ↓ 内部では
kAudioUnitProperty_MakeConnection（低レベル）
    ↓ より高レベルでは（deprecated）
AUGraphConnectNodeInput
```

---

## 次のステップへの問い

1. プルモデルにおいて「誰が誰にデータを要求するか」を図で説明できるか？
2. `inRefCon` に `Unmanaged.passUnretained` を使う理由は何か？ `passRetained` との違いは？
3. コールバック内で `malloc` が禁止される理由を「Priority Inversion」という言葉を使って説明できるか？

これらに答えられたら **Step 4: リアルタイムスレッドの制約を理解する** へ進む。
