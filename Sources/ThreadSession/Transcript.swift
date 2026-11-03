import Foundation

public enum Role: String, Sendable, Equatable {
    case user, assistant
}

/// One block of message content, mirroring the Messages API's content-block model.
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    /// `input` is the tool's JSON input as the model produced it. It is digested verbatim, so two
    /// semantically equal inputs with different key order are different calls. Canonicalising JSON
    /// was rejected: the model's own output is already deterministic for an identical prefix, and a
    /// canonicaliser is one more parser on the hot path.
    case toolUse(id: String, name: String, input: String)
    case toolResult(toolUseID: String, output: String, isError: Bool)
}

public struct Message: Sendable, Equatable {
    public let role: Role
    public let blocks: [ContentBlock]

    public init(role: Role, blocks: [ContentBlock]) {
        self.role = role
        self.blocks = blocks
    }

    public static func user(_ text: String) -> Message { Message(role: .user, blocks: [.text(text)]) }
    public static func assistant(_ text: String) -> Message { Message(role: .assistant, blocks: [.text(text)]) }

    public var toolUses: [(id: String, name: String, input: String)] {
        blocks.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
            return nil
        }
    }

    public var plainText: String {
        blocks.compactMap {
            switch $0 {
            case let .text(t): return t
            case let .toolUse(_, name, input): return "→ \(name)(\(input))"
            case let .toolResult(_, output, isError): return isError ? "✗ \(output)" : "← \(output)"
            }
        }.joined(separator: "\n")
    }
}

/// How an entry's digest is computed. Injectable so the tests can prove that the prefix check
/// depends on *chaining* — a digester that ignores the previous digest must make the check fail.
public protocol TranscriptDigester: Sendable {
    func digest(previous: StableDigest, message: Message) -> StableDigest
}

/// The production digester: each entry's digest folds in the previous entry's digest, so the
/// digest of entry *n* commits to the entire prefix `0...n`.
public struct ChainedDigester: TranscriptDigester {
    public init() {}
    public func digest(previous: StableDigest, message: Message) -> StableDigest {
        var d = StableDigest.seed.folding(digest: previous).folding(field: message.role.rawValue)
        d = d.folding(UInt64(message.blocks.count).littleEndianBytes)
        for block in message.blocks {
            switch block {
            case let .text(t):
                d = d.folding(tag: 1).folding(field: t)
            case let .toolUse(id, name, input):
                d = d.folding(tag: 2).folding(field: id).folding(field: name).folding(field: input)
            case let .toolResult(id, output, isError):
                d = d.folding(tag: 3).folding(field: id).folding(field: output).folding(tag: isError ? 1 : 0)
            }
        }
        return d
    }
}

public struct TranscriptEntry: Sendable, Equatable {
    public let index: Int
    public let message: Message
    public let digest: StableDigest
}

/// An append-only, content-addressed conversation log. This is the client's source of truth:
/// the server thread is a *cache* of it, and anything the cache loses is rebuilt from here.
public struct Transcript: Sendable {
    public private(set) var entries: [TranscriptEntry] = []
    private let digester: any TranscriptDigester

    public init(digester: any TranscriptDigester = ChainedDigester()) {
        self.digester = digester
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var messages: [Message] { entries.map(\.message) }

    /// Digest of the whole transcript; `seed` when empty.
    public var headDigest: StableDigest { entries.last?.digest ?? .seed }

    /// Digest of the first `count` entries; `nil` when `count` is out of range.
    public func digest(ofPrefix count: Int) -> StableDigest? {
        guard count >= 0, count <= entries.count else { return nil }
        if count == 0 { return .seed }
        return entries[count - 1].digest
    }

    @discardableResult
    public mutating func append(_ message: Message) -> TranscriptEntry {
        let entry = TranscriptEntry(
            index: entries.count,
            message: message,
            digest: digester.digest(previous: headDigest, message: message)
        )
        entries.append(entry)
        return entry
    }

    /// Messages after the first `count`. Out-of-range values clamp instead of trapping.
    public func messages(after count: Int) -> [Message] {
        let start = min(max(count, 0), entries.count)
        return entries[start...].map(\.message)
    }

    /// Drops everything after the first `count` entries (used to roll back a failed turn).
    public mutating func truncate(to count: Int) {
        let keep = min(max(count, 0), entries.count)
        entries.removeSubrange(keep...)
    }

    /// Replaces the message at `index` and re-chains everything after it. Models a user editing
    /// or redacting history — which is exactly what invalidates the server's copy.
    public mutating func rewrite(at index: Int, with message: Message) {
        guard entries.indices.contains(index) else { return }
        var rebuilt = Transcript(digester: digester)
        for (i, e) in entries.enumerated() {
            rebuilt.append(i == index ? message : e.message)
        }
        self = rebuilt
    }
}
