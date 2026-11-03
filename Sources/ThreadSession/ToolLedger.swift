import Foundation

/// Identity of one side-effecting tool call within one user turn.
///
/// - `turnDigest`: the transcript digest *at the user message that opened the turn*. The same
///   message on the same history gives the same digest, so a retried turn shares keys with the
///   failed attempt; a different message, or the same message later in the conversation, does not.
/// - `occurrence`: 1 for the first call with this (name, input) in the turn attempt, 2 for the
///   second, … so a model that legitimately calls the same tool twice is not collapsed into one.
public struct ToolCallKey: Hashable, Sendable {
    public let turnDigest: StableDigest
    public let name: String
    public let inputDigest: StableDigest
    public let occurrence: Int
}

/// At-most-once execution for side-effecting tools across turn retries.
///
/// A user turn is **atomic** in this design: if any request in it fails, the transcript rolls
/// back to before the user message, because a transcript ending in an unanswered `tool_use` is
/// not a valid conversation. Rolling back the transcript must not roll back the *world* — a
/// reminder that was already created stays created — so the ledger outlives the rollback and
/// answers a re-issued call from its record instead of executing it again.
///
/// Bounded: it keeps the most recent `capacity` results (FIFO eviction). Eviction can only cause
/// a re-execution for a turn retried after `capacity` newer side-effecting calls — a trade-off
/// against unbounded growth in a long-running agent session.
public struct ToolLedger: Sendable {
    public let capacity: Int
    private var results: [ToolCallKey: String] = [:]
    private var order: [ToolCallKey] = []

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { results.count }

    public func result(for key: ToolCallKey) -> String? { results[key] }

    public mutating func record(_ output: String, for key: ToolCallKey) {
        if results.updateValue(output, forKey: key) == nil {
            order.append(key)
        }
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            results.removeValue(forKey: oldest)
        }
    }

    public mutating func removeAll() {
        results.removeAll()
        order.removeAll()
    }
}

/// Builds `ToolCallKey`s for one turn attempt, counting occurrences.
struct ToolCallKeyMaker {
    let turnDigest: StableDigest
    private var seen: [String: Int] = [:]

    init(turnDigest: StableDigest) { self.turnDigest = turnDigest }

    mutating func key(name: String, input: String) -> ToolCallKey {
        let inputDigest = StableDigest.seed.folding(field: input)
        let slot = name + "\u{1F}" + inputDigest.description
        let n = Saturating.add(seen[slot, default: 0], 1)
        seen[slot] = n
        return ToolCallKey(turnDigest: turnDigest, name: name, inputDigest: inputDigest, occurrence: n)
    }
}
