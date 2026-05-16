# Step 4: リアルタイムスレッドの制約を理解する

## 学習目標

リアルタイムスレッドで何が起きているかを理解し、
UI スレッドとオーディオスレッド間のデータ受け渡しを安全に実装できるようになる。

---

## 学べること

### 1. Priority Inversion の仕組み

`malloc` がリアルタイムスレッドで禁止される理由。

```
通常時:
  リアルタイムスレッド（高優先度）が CPU を使用

malloc を呼んだとき:
  1. 低優先度スレッドがヒープのロック（mutex）を取得して malloc 中
  2. リアルタイムスレッドも malloc を呼ぼうとする
  3. ロックが取れないのでリアルタイムスレッドがブロック
  4. 高優先度スレッドが低優先度スレッドのロック解放を「待つ」
        → 優先度が高いのに低優先度スレッドに依存して止まる
        = Priority Inversion（優先順位の逆転）
```

結果: スピーカーへの音声供給が途切れ、**ノイズ・クリックノイズ・無音**が発生する。

### 2. Step 3 の実装の問題点

```swift
// Step 3 の ViewModel（安全でない）
func updateFrequency(_ hz: Double) {
    engine.frequency = hz          // UIスレッドから直接書き換え
}

// コールバック内（オーディオスレッド）
let phaseIncrement = 2.0 * Double.pi * ctx.frequency / ctx.sampleRate
//                                      ↑ 同時に読んでいる可能性
```

両スレッドが同じ変数に同時アクセスする**データ競合（Data Race）**が発生しうる。
Double は 64bit のため、ARM では通常アトミックに読み書きされるが、これはハードウェア依存であり保証されない。

### 3. 安全な解決策: SPSC Ring Buffer

SPSC = **S**ingle **P**roducer **S**ingle **C**onsumer

```
UIスレッド（Producer）          オーディオスレッド（Consumer）
    ↓ enqueue                        dequeue ↓
    writeIndex だけを更新     readIndex だけを更新
         ↓                               ↑
    [ cmd0 | cmd1 | cmd2 | ... ]  ← Ring Buffer
```

**なぜロック不要か**: Producer は `writeIndex` だけを、Consumer は `readIndex` だけを更新する。
両スレッドが同じ変数を同時に書き換えることがないため、ロックなしで安全に動作する。

**なぜ malloc 不要か**: バッファを事前に確保し、固定サイズの配列を使い回すため。

### 4. コマンドパターン

パラメータ変更を「コマンド」として Queue に積む。

```swift
enum AudioCommand {
    case setFrequency(Double)
    case setVolume(Float)
}

// UIスレッド側
queue.enqueue(.setFrequency(880))   // ロックなし・即時返却

// オーディオスレッド（コールバック冒頭）
while let cmd = queue.dequeue() {   // ロックなし
    switch cmd {
    case .setFrequency(let hz): ctx.frequency = hz
    case .setVolume(let vol):   ctx.volume = vol
    }
}
```

コールバック冒頭でコマンドを処理することで、
そのコールバック呼び出し内では `ctx` の値が安定した状態でサンプル生成できる。

### 5. リアルタイムスレッドの禁止操作まとめ

| 禁止操作 | 理由 | 代替手段 |
|---|---|---|
| `malloc` / `free` | ヒープロックで Priority Inversion | 事前確保・Ring Buffer |
| `DispatchQueue.async` | 内部で malloc / lock | 事前にコマンドをキューイング |
| ObjC メッセージ送信 | ランタイムがロックを取得 | C / C++ 関数を使用 |
| `mutex` / `os_unfair_lock` | 待機が発生しうる | Lock-free Queue |
| ファイル I/O / ネットワーク | ブロッキング操作 | 事前読み込み |
| Swift クラスの retain/release | ARC が内部でロック | `Unmanaged` で制御 |
| `print` / ログ出力 | I/O・malloc が発生 | デバッグ時のみ使用 |

---

## 確認手順（アプリでの操作）

### 確認1: 再生しながらパラメータを変更

再生中にスライダーで周波数・音量を変更し、クリックノイズなく変化することを確認する。

**なぜ重要か**  
`LockFreeQueue` 経由のコマンドがコールバック冒頭で処理されることで、
サンプル生成中に値が変化しないことが保証されている。

---

### 確認2: Step 3 との実装の違いを比較

| | Step 3 | Step 4 |
|---|---|---|
| 周波数変更 | `ctx.frequency = newValue`（直接）| `queue.enqueue(.setFrequency(hz))`（Queue 経由）|
| 安全性 | データ競合の可能性あり | SPSC で安全 |
| コールバック内の処理 | サンプル生成のみ | コマンド処理 → サンプル生成 |

---

## 本実装の限界（プロダクション環境向け）

本実装の `LockFreeQueue` は教育用の簡略版。
`writeIndex` / `readIndex` の更新が厳密なアトミック操作ではないため、
プロダクション環境では以下を使用する。

| ライブラリ | 特徴 |
|---|---|
| **TPCircularBuffer** | iOS 音声開発で広く使われる C ライブラリ |
| **Swift Atomics** | Apple 公式の Swift アトミック操作パッケージ |
| **Swift 6 `Atomic`** | Swift 標準ライブラリへの組み込み（iOS 18+）|

---

## 次のステップへの問い

1. SPSC Ring Buffer が「Producer は writeIndex だけ、Consumer は readIndex だけ更新する」ことでロック不要になる理由を説明できるか？
2. `os_unfair_lock` はリアルタイムスレッドで使えるか？　その理由は？
3. コマンドをコールバックの「冒頭」で処理する理由は何か？ 末尾で処理するとどうなるか？

これらに答えられたら **Step 5: DSP 基礎（FFT・フィルター）** へ進む。
