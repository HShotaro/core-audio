import Foundation

// SPSC (Single Producer Single Consumer) Lock-Free Ring Buffer
//
// Producer: UI スレッド（enqueue）
// Consumer: オーディオスレッド（dequeue）
//
// writeIndex は Producer のみが更新する。
// readIndex は Consumer のみが更新する。
// 両者が別々のインデックスだけを更新するため、ロックなしで安全に動作する。
//
// 注意: 本実装は教育用の簡略版。
// プロダクション環境では TPCircularBuffer や Swift Atomics パッケージの使用を推奨。
final class LockFreeQueue<T> {
    private let capacity: Int
    private var buffer: [T?]
    private var writeIndex: Int = 0  // Producer（UIスレッド）のみ更新
    private var readIndex: Int = 0   // Consumer（オーディオスレッド）のみ更新

    init(capacity: Int = 64) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    // UIスレッドから呼ぶ（Producer）
    // バッファが満杯のとき false を返す（ブロックしない）
    func enqueue(_ item: T) -> Bool {
        let nextWrite = (writeIndex + 1) % capacity
        guard nextWrite != readIndex else { return false }
        buffer[writeIndex] = item
        writeIndex = nextWrite
        return true
    }

    // オーディオスレッドから呼ぶ（Consumer）
    // データがないとき nil を返す（ブロックしない）
    func dequeue() -> T? {
        guard readIndex != writeIndex else { return nil }
        let item = buffer[readIndex]
        readIndex = (readIndex + 1) % capacity
        return item
    }
}
