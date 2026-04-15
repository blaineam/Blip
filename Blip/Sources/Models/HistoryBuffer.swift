import Foundation

/// Fixed-size ring buffer for storing historical metric samples.
/// Efficient O(1) append, O(1) access, zero allocations after init.
struct HistoryBuffer<T: Sendable>: Sendable {
    private var storage: [T]
    private var head: Int = 0
    private var count_: Int = 0
    let capacity: Int

    init(capacity: Int, defaultValue: T) {
        self.capacity = capacity
        self.storage = Array(repeating: defaultValue, count: capacity)
    }

    mutating func append(_ value: T) {
        storage[head] = value
        head = (head + 1) % capacity
        if count_ < capacity { count_ += 1 }
    }

    var count: Int { count_ }
    var isFull: Bool { count_ == capacity }

    /// Returns values oldest-first.
    var values: [T] {
        if count_ < capacity {
            return Array(storage[0..<count_])
        }
        return Array(storage[head..<capacity]) + Array(storage[0..<head])
    }

    var latest: T? {
        guard count_ > 0 else { return nil }
        let idx = head == 0 ? capacity - 1 : head - 1
        return storage[idx]
    }
}
