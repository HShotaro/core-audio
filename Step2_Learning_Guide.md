# Step 2: VPIO の内側を理解する

## 学習目標

`kAudioUnitSubType_VoiceProcessingIO` の正体を C API で確認し、
AEC / AGC / VAD が何をしているかを原理から説明できるようになる。
「なぜコラボ配信で VPIO が必要だったのか」を自分の言葉で説明できるようになる。

---

## 学べること

### 1. VPIO は RemoteIO の拡張

componentSubType が `rioc`（RemoteIO）から `vpio` に変わるだけ。
バス構造は RemoteIO と完全に同じ。

```swift
var desc = AudioComponentDescription(
    componentType:         kAudioUnitType_Output,
    componentSubType:      kAudioUnitSubType_VoiceProcessingIO, // "vpio"
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags:        0,
    componentFlagsMask:    0
)
```

| | RemoteIO | VPIO |
|---|---|---|
| componentType | `auou` | `auou` |
| componentSubType | `rioc` | `vpio` |
| Bus 0 (Output) | ✅ | ✅ |
| Bus 1 (Input) | ✅ | ✅ |
| AEC | ❌ | ✅ |
| AGC | ❌ | ✅ |
| VAD | ❌ | ✅ |

#### バス構造（RemoteIO と同一）

```
【アプリ側】                    VPIO AU                   【ハードウェア側】

  音声データを書き込む  →  Bus 0, kAudioUnitScope_Input  →  スピーカー
  （AUへの入力）

  音声データを読み取る  ←  Bus 1, kAudioUnitScope_Output ←  マイク
  （AUからの出力）                                              ↑
                                                        AEC がここで
                              ┌── 参照信号 ────────────────┐  エコー除去
                              │  （Bus 0 の出力内容）       │
                         [AEC / AGC / VAD]  ←────────────┘
```

Bus 0 の出力内容（スピーカーへ送った音）を参照信号として、Bus 1 のマイク入力からエコーを差し引く。
これが VPIO が I/O ユニットである必要がある理由。RemoteIO では出力と入力が別ユニットになるため
この参照信号の受け渡しが自前になる。

### 2. VPIO が自動でやっていること

#### AEC（Acoustic Echo Cancellation）— エコーキャンセル

コラボ配信でなぜ必要か：

```
相手の声がスピーカーから流れる
　　↓
マイクがスピーカー音を拾う（エコー）
　　↓
AEC がスピーカー出力を「参照信号」として
マイク入力から差し引く
　　↓
相手に自分の声だけが届く
```

VPIO が I/O ユニットである理由がここにある。AEC は**出力信号（参照信号）とマイク入力に同時アクセス**する必要があるため、I/O を担う VPIO でなければ実現できない。RemoteIO で AEC を実現しようとすると、出力信号を別途参照信号として渡す仕組みを自前で実装する必要がある。

#### AGC（Auto Gain Control）— 自動音量調整

マイクから遠ざかっても、近づきすぎても、適切な音量に自動調整する。
ゲインを動的に制御するため、話者の距離変化や環境変化に追従する。

##### 計算の仕組み

**Step 1: RMS で現在の音量を測定**

瞬間値ではなく一定ウィンドウ内の RMS（Root Mean Square）で測定する。
瞬間値だと無音→大声の変化に過剰反応するため。

```
RMS = sqrt( (x[0]² + x[1]² + ... + x[N-1]²) / N )
```

**Step 2: dB に変換して目標値と比較**

```
level_dB  = 20 * log10(RMS)
error_dB  = target_dB - level_dB   // 例: target = -18 dBFS
```

`error_dB` がプラス → 小さすぎる → ゲインを上げる  
`error_dB` がマイナス → 大きすぎる → ゲインを下げる

**Step 3: Attack / Release レートでゲインをゆっくり更新**

```
if error_dB < 0 {
    gain_dB += error_dB * attack_rate   // 大きすぎる → 速く下げる
} else {
    gain_dB += error_dB * release_rate  // 小さすぎる → ゆっくり上げる
}
```

Attack（下げる速さ）は速く、Release（上げる速さ）は遅くするのがポイント。
逆にすると大声のあとに急激にゲインが上がりノイズが目立つ「ポンピング」が発生する。

**Step 4: ゲインをサンプルに乗算**

```
output[i] = input[i] * 10^(gain_dB / 20)
```

**データフロー**

```
マイク入力
    ↓
[RMS測定] → level_dB
    ↓
[目標値と比較] → error_dB
    ↓
[Attack/Release] → gain_dB（ゆっくり変化）
    ↓
[乗算] → 出力
    ↑
  フィードバック（次フレームの測定へ）
```

##### AGC とコンプレッサーの違い

混同しやすいが、**時定数**が根本的に異なる。

| | AGC | コンプレッサー |
|---|---|---|
| 目的 | 長期的な音量を一定に保つ | 瞬間的なピークを抑える |
| Attack | 数百ms〜秒単位 | 数ms単位 |
| Release | 数秒単位 | 数十ms単位 |
| 用途 | 話者の距離変化・環境変化への追従 | クリッピング防止・音圧稼ぎ |

VPIO の AGC は話者の距離変化への追従が目的のため時定数が長め。
Apple は具体的なアルゴリズムを非公開にしているが、この RMS + Attack/Release の構造が一般的な実装。
`kAUVoiceIOProperty_VoiceProcessingEnableAGC` で ON/OFF できるのは RMS測定→比較→ゲイン更新→乗算の一連の計算ステップ。

##### Global Scope について

このプロパティに `kAudioUnitScope_Global` を指定するのは、AGC の有効/無効が「特定バスの設定」ではなく「VPIO インスタンス全体の動作モードの設定」だから。

| Scope | 意味 | 使用場面 |
|---|---|---|
| `kAudioUnitScope_Global` | AU インスタンス全体に適用 | 機能の ON/OFF、モード切替など |
| `kAudioUnitScope_Input` | 特定の入力バスに適用 | バスごとのフォーマット・ゲインなど |
| `kAudioUnitScope_Output` | 特定の出力バスに適用 | バスごとのフォーマット・ゲインなど |

AGC は Bus 1（マイク入力）の処理だが、「AGC という機能を持つかどうか」はバス単位の設定ではないため Global。
`kAUVoiceIOProperty_BypassVoiceProcessing` や `kAUVoiceIOProperty_MuteOutput` も同様に Global Scope を使う。

#### VAD（Voice Activity Detection）— 音声区間検出

音声が存在するかどうかを判定する。無音区間での不要な処理を省いたり、
ノイズゲート的な役割を果たす。AGC と連動して動作する。

### 3. C API でプロパティを制御する

VPIO 固有のプロパティは `kAUVoiceIOProperty_*` プレフィックスで定義されている。
Scope は常に `kAudioUnitScope_Global`、Bus は `0`。

```swift
// AEC・AGC・VAD をまとめてバイパス（1=バイパスON=DSP無効）
var bypass: UInt32 = 1
AudioUnitSetProperty(
    vpio,
    kAUVoiceIOProperty_BypassVoiceProcessing,
    kAudioUnitScope_Global,
    0,
    &bypass,
    UInt32(MemoryLayout<UInt32>.size)
)

// AGC だけ個別に制御
var agc: UInt32 = 0  // 0=無効
AudioUnitSetProperty(
    vpio,
    kAUVoiceIOProperty_VoiceProcessingEnableAGC,
    kAudioUnitScope_Global,
    0,
    &agc,
    UInt32(MemoryLayout<UInt32>.size)
)
```

| プロパティ | 意味 | デフォルト |
|---|---|---|
| `kAUVoiceIOProperty_BypassVoiceProcessing` | AEC・AGC・VAD をまとめてOFF | 0（有効）|
| `kAUVoiceIOProperty_VoiceProcessingEnableAGC` | AGC の有効/無効 | 1（有効）|
| `kAUVoiceIOProperty_MuteOutput` | 出力ミュート | 0（ミュートなし）|

### 4. VPIO のコスト

#### レイテンシが増加する理由

VPIO は DSP 処理を追加するため、RemoteIO より**レイテンシが増加**する。
主な原因は AEC の仕組みにある。

**AEC が必要とする処理**

1. スピーカーから音が出てマイクに届くまでの「伝播遅延」を考慮した位置合わせ
2. 参照信号（スピーカー出力）とマイク入力の相関計算（適応フィルター）
3. 相関を取るために一定量のサンプルが揃うまで待つ必要がある

このため VPIO は RemoteIO より**大きなバッファサイズ**を必要とする。

#### バッファサイズとレイテンシの関係

まずサンプルレートとサンプルの関係を理解する。

**サンプルレート 48000 Hz = 1秒間に 48000 個のサンプルが流れる**

```
1秒間のサンプル列（48000 Hz）

|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|s|...  48000個/秒
 ↑1サンプル = 1/48000 秒 ≒ 0.02 ms
```

バッファとは「一定数のサンプルが溜まるまで待つ箱」。
箱が満杯になって初めて処理（AEC・AGC・ピッチ補正等）が実行される。

```
バッファサイズ 256 samples の場合（RemoteIO 最小）

時間 →
|s|s|s|s|s|s|s|...|s|  ← 256個溜まったら処理
 ←── 256 / 48000 秒 ──→
      = 5.3 ms でコールバック発火


バッファサイズ 1024 samples の場合（VPIO 最小）

|s|s|s|s|s|s|s|s|s|s|s|s|s|...|s|  ← 1024個溜まったら処理
 ←────── 1024 / 48000 秒 ──────→
           = 21.3 ms でコールバック発火
```

**計算式**

```
レイテンシ（ms） = バッファサイズ（samples） / サンプルレート（Hz） × 1000
```

| バッファサイズ | 48000 Hz | 44100 Hz |
|---|---|---|
| 256 samples | 5.3 ms | 5.8 ms |
| 512 samples | 10.7 ms | 11.6 ms |
| 1024 samples | 21.3 ms | 23.2 ms |
| 4096 samples | 85.3 ms | 92.9 ms |

**VPIO のレイテンシが 40ms 以上になる理由**

AEC は「バッファを受け取って処理してバッファを返す」という処理を 2 回分経由する。

```
マイク入力         AEC 処理            出力
   ↓                  ↓                 ↓
[バッファ蓄積]  → [バッファ蓄積]  → [バッファ蓄積]
 21.3 ms 待つ    21.3 ms 待つ       21.3 ms 待つ
                                   ↑
                          合計: 約 40〜60 ms
```

| | RemoteIO | VPIO |
|---|---|---|
| 最小バッファサイズ | ~256 samples（~5ms） | ~1024 samples（~21ms）|
| AEC 処理遅延 | なし | +1バッファ分（~21ms）|
| 合計レイテンシ目安 | ~5ms | ~40ms以上 |

RemoteIO で最小バッファを使うと約5msまで下げられるが、VPIO では AEC が機能するために十分なサンプル数が必要なため、実質的に40ms以上になることが多い。

#### バッファサイズの設定

`AVAudioSession` でバッファ時間を設定しても、VPIO は内部で下限を持つ。

```swift
// 要求しても VPIO の下限に丸められることがある
try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005) // 5ms を要求
let actual = AVAudioSession.sharedInstance().ioBufferDuration // 実際は大きい値になる
```

#### AEC 品質とレイテンシのトレードオフ

```
バッファサイズ 小 → レイテンシ 低  ↔  AEC 品質 低（相関計算のサンプル不足）
バッファサイズ 大 → レイテンシ 高  ↔  AEC 品質 高（十分なサンプルで精度向上）
```

Apple の VPIO はこのトレードオフを内部で自動調整しているが、チューニングはできない。

#### カラオケ・コラボ配信への影響

**カラオケアプリ（ピッチ補正・BPM同期）**

- ピッチ補正はマイク入力に対してリアルタイムで処理するため、VPIO のレイテンシ増加が**歌い心地に直結**する
- BPM 同期では「実際に音が出るタイミング」と「処理タイミング」のズレを、バッファサイズから逆算して補正する必要がある

```
出力タイミング補正 = -(VPIOバッファサイズ / サンプルレート)
```

**コラボ配信**

エンドツーエンドのレイテンシは VPIO の処理遅延が固定コストとして加わる。

```
E2E レイテンシ = VPIO処理遅延（~40ms）
               + エンコード遅延
               + ネットワーク遅延
               + デコード遅延
               + 相手側の再生バッファ
```

VPIO のレイテンシは削減できないため、ネットワーク遅延やバッファ設計で全体を最適化する必要がある。

---

## 確認手順（アプリでの操作）

### 確認1: VPIO の componentSubType

「VPIO を生成して検査」をタップ後、正体セクションを確認する。

**確認すること**
- `componentType` が `auou`（RemoteIO と同じ）であること
- `componentSubType` が `vpio`（RemoteIO の `rioc` と異なる）であること

---

### 確認2: デフォルトのプロパティ値

**確認すること**
- `BypassVoiceProcessing` がデフォルトで `OFF`（= AEC 有効）であること
- `VoiceProcessingEnableAGC` がデフォルトで `ON` であること

**なぜ重要か**  
コラボ配信の実装時に「デフォルトで AEC が有効になっている」ことを知らないと、
AEC を意図せずバイパスした状態でリリースしてしまうリスクがある。

---

### 確認3: Bypass のトグル

実機でイヤホンなしでスピーカー再生しながら VPIO を動かし、
`BypassVoiceProcessing` を ON/OFF して音の変化を観察する。

**Bypass=ON（AEC無効）**: スピーカー音がマイクに回り込みエコーが発生する  
**Bypass=OFF（AEC有効）**: エコーが除去される

---

## AVAudioEngine での対応

iOS 14 以降、`AVAudioEngine.setVoiceProcessingEnabled(_:)` で内部の I/O ユニットを
RemoteIO から VPIO に切り替えられる。

```swift
let engine = AVAudioEngine()
try engine.setVoiceProcessingEnabled(true)
// → engine.inputNode / outputNode の背後が RemoteIO から VPIO に切り替わる
try engine.start()
```

C API との対応：

| AVAudioEngine | C API 相当 |
|---|---|
| `setVoiceProcessingEnabled(true)` | `kAudioUnitSubType_VoiceProcessingIO` でインスタンス生成 |
| `setVoiceProcessingEnabled(false)` | `kAudioUnitSubType_RemoteIO` に戻す |

`setVoiceProcessingEnabled` は `start()` の前に呼ぶ必要がある（初期化前に I/O ユニットを決定するため）。
iOS 13 以前をサポートする場合は C API で VPIO を直接生成する方法が必要になる。

---

## 次のステップへの問い

1. AEC が機能するために VPIO が I/O ユニットである必要がある理由は何か？
2. `BypassVoiceProcessing` と `VoiceProcessingEnableAGC` の違いは何か？ どちらが上位の制御か？
3. VPIO を使うとレイテンシが増加する理由は何か？

これらに答えられたら **Step 3: AU の接続を C API で実装する（AUGraph / RenderCallback）** へ進む。
