import Foundation

/// Which lifecycle path a request took. This is the dimension a lead actually needs on a
/// dashboard: "35% faster TTFT" is only true for `.delta`, and a mobile app spends a large share
/// of its turns on the other paths.
public enum TurnPath: Sendable, Equatable {
    case started
    case delta
    case rehydrated(ResendReason)
    case keepWarm
    case rejectedDelta
    case failed

    public var label: String {
        switch self {
        case .started: return "start"
        case .delta: return "delta"
        case let .rehydrated(r): return "rehydrate·\(r.rawValue)"
        case .keepWarm: return "keep-warm"
        case .rejectedDelta: return "delta rejected"
        case .failed: return "failed"
        }
    }
}

public struct TurnRecord: Sendable, Equatable, Identifiable {
    public let id: Int
    public let path: TurnPath
    /// Estimated tokens put on the wire for this request.
    public let uploadedTokens: Int
    /// Estimated tokens Claude reads for this request (the whole conversation).
    public let contextTokens: Int
    /// `nil` when the request produced no response.
    public let ttftMs: Double?
    public let at: TimeInterval
}

/// Fixed-capacity ring buffer. A long-running agent session must not grow memory per turn.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0  // index of the oldest element once full

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            // `head` is always in 0..<capacity and storage.count == capacity here.
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    public var elements: [Element] {
        guard storage.count == capacity, head > 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }
}

/// Estimates tokens from text. Defaults to ~4 characters per token; inject a real tokenizer count
/// from the relay if you need billing-grade numbers.
public protocol TokenEstimator: Sendable {
    func tokens(in message: Message) -> Int
}

public struct CharacterTokenEstimator: TokenEstimator {
    public let charactersPerToken: Int
    public init(charactersPerToken: Int = 4) { self.charactersPerToken = max(1, charactersPerToken) }

    public func tokens(in message: Message) -> Int {
        var chars = 0
        for block in message.blocks {
            switch block {
            case let .text(t): chars = Saturating.add(chars, t.count)
            case let .toolUse(id, name, input): chars = Saturating.add(chars, Saturating.add(id.count, Saturating.add(name.count, input.count)))
            case let .toolResult(id, output, _): chars = Saturating.add(chars, Saturating.add(id.count, output.count))
            }
        }
        // Round up without `chars + n - 1`, which could overflow near Int.max.
        let (q, r) = chars.quotientAndRemainder(dividingBy: charactersPerToken)
        return r > 0 ? Saturating.add(q, 1) : q
    }
}

extension TokenEstimator {
    func tokens(in messages: [Message]) -> Int {
        messages.reduce(0) { Saturating.add($0, tokens(in: $1)) }
    }
}
