import Foundation

/// What the client knows about the server-side thread after the last successful request.
public struct ThreadAnchor: Sendable, Equatable {
    public let threadID: String
    public let lastResponseID: String
    /// Number of transcript entries the server thread holds.
    public let syncedCount: Int
    /// Digest of that prefix at the time it was synced.
    public let syncedDigest: StableDigest
    /// When the last request was **sent** (not when its response arrived). The server's TTL starts
    /// when the request *arrives*, which is later, so measuring from send time errs early.
    public let lastRequestAt: TimeInterval

    public init(threadID: String, lastResponseID: String, syncedCount: Int, syncedDigest: StableDigest, lastRequestAt: TimeInterval) {
        self.threadID = threadID
        self.lastResponseID = lastResponseID
        self.syncedCount = syncedCount
        self.syncedDigest = syncedDigest
        self.lastRequestAt = lastRequestAt
    }
}

/// Client-side model of the server's thread lifetime.
public struct TTLPolicy: Sendable, Equatable {
    /// The server's idle TTL. Message threads expire 5 minutes after the last request.
    public let serverTTL: TimeInterval
    /// Subtracted from the TTL to absorb request transit time and server-side clock behaviour.
    public let safetyMargin: TimeInterval
    /// Width of the "expiring" band before the effective deadline, where keep-warm is considered.
    public let expiringWindow: TimeInterval

    /// Invalid inputs are repaired rather than trusted: non-finite or non-positive TTL falls back to
    /// 300 s, and margin/window are clamped into `[0, ttl)`.
    public init(serverTTL: TimeInterval = 300, safetyMargin: TimeInterval = 15, expiringWindow: TimeInterval = 60) {
        let ttl = (serverTTL.isFinite && serverTTL > 0) ? serverTTL : 300
        let margin = safetyMargin.isFinite ? min(max(safetyMargin, 0), ttl * 0.5) : 0
        let window = expiringWindow.isFinite ? min(max(expiringWindow, 0), ttl - margin) : 0
        self.serverTTL = ttl
        self.safetyMargin = margin
        self.expiringWindow = window
    }

    public var effectiveTTL: TimeInterval { serverTTL - safetyMargin }

    public enum Liveness: Sendable, Equatable {
        case live(remaining: TimeInterval)
        case expiring(remaining: TimeInterval)
        case expired
    }

    /// Classifies a thread last used at `lastRequestAt`.
    ///
    /// Fails toward **full resend**: a backwards clock or a non-finite reading reports `.expired`.
    /// A full resend is always correct; a delta to a dead thread costs a rejected round trip.
    public func liveness(lastRequestAt: TimeInterval, now: TimeInterval) -> Liveness {
        guard lastRequestAt.isFinite, now.isFinite else { return .expired }
        let elapsed = now - lastRequestAt
        guard elapsed >= 0 else { return .expired }
        let remaining = effectiveTTL - elapsed
        if remaining <= 0 { return .expired }
        if remaining <= expiringWindow { return .expiring(remaining: remaining) }
        return .live(remaining: remaining)
    }
}

public enum ResendReason: String, Sendable, Equatable, CaseIterable {
    /// No thread has been started yet.
    case noThread
    /// The client's clock says the thread is past its effective TTL.
    case expiredLocally
    /// Local history no longer matches what the server holds (rollback, edit, redaction).
    case prefixDiverged
    /// The client thought the thread was live, but the server rejected the delta.
    case serverRejected
    /// A failed turn rolled back messages the server had already received.
    case rolledBack
}

public enum TurnPlan: Sendable, Equatable {
    /// Send only the messages the server has not seen.
    case delta(threadID: String, previousResponseID: String, newMessages: [Message])
    /// Send the whole transcript and start a new thread.
    case fullResend(messages: [Message], reason: ResendReason)

    public var isDelta: Bool { if case .delta = self { return true }; return false }
}

/// Pure decision: delta or full resend. No I/O, no clock reads — every input is a parameter, so
/// every branch is unit-testable.
public enum TurnPlanner {
    public static func plan(anchor: ThreadAnchor?, transcript: Transcript, now: TimeInterval, policy: TTLPolicy) -> TurnPlan {
        guard let anchor else {
            return .fullResend(messages: transcript.messages, reason: .noThread)
        }
        if case .expired = policy.liveness(lastRequestAt: anchor.lastRequestAt, now: now) {
            return .fullResend(messages: transcript.messages, reason: .expiredLocally)
        }
        // A delta is only correct if the server's prefix is *exactly* our prefix. Checking the
        // count alone misses an edit in the middle; the chained digest catches it.
        guard anchor.syncedCount < transcript.count,
              let local = transcript.digest(ofPrefix: anchor.syncedCount),
              local == anchor.syncedDigest
        else {
            return .fullResend(messages: transcript.messages, reason: .prefixDiverged)
        }
        return .delta(
            threadID: anchor.threadID,
            previousResponseID: anchor.lastResponseID,
            newMessages: transcript.messages(after: anchor.syncedCount)
        )
    }
}
