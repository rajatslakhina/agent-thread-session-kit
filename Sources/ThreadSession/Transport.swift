import Foundation

/// A request the session hands to its transport. The transport maps it onto the wire.
///
/// In production that transport talks to **your backend-for-frontend relay**, not to the
/// Messages API directly: the relay owns the API key and adds the `thread` parameter. This
/// library deliberately does not encode the beta's JSON field names — they belong to the relay,
/// which can change with the beta without an App Store release.
public enum ThreadRequest: Sendable, Equatable {
    /// Start a new thread with the full conversation.
    case start(messages: [Message])
    /// Continue an existing thread with only the new messages.
    case `continue`(threadID: String, previousResponseID: String, newMessages: [Message])

    public var messages: [Message] {
        switch self {
        case let .start(m): return m
        case let .continue(_, _, m): return m
        }
    }
}

public struct ThreadResponse: Sendable, Equatable {
    public let threadID: String
    public let responseID: String
    public let message: Message
    /// Time to first token as observed (or, in the simulator, modelled) for this request.
    public let ttftMs: Double

    public init(threadID: String, responseID: String, message: Message, ttftMs: Double) {
        self.threadID = threadID
        self.responseID = responseID
        self.message = message
        self.ttftMs = ttftMs
    }
}

public enum ThreadTransportError: Error, Sendable, Equatable {
    /// The server no longer holds this thread (TTL elapsed or evicted).
    case threadExpired
    /// The previous-response ID is not the thread's head (another client advanced it, or a
    /// response was lost in transit).
    case responseIDMismatch
    /// Anything else: offline, timeout, 5xx. Not retried by the session.
    case transport(String)
}

public protocol ThreadTransport: Sendable {
    func send(_ request: ThreadRequest) async throws -> ThreadResponse
    /// Refreshes the thread's TTL and returns what that did to the thread.
    ///
    /// **The message-threads beta exposes no keep-alive.** A thread is refreshed only by a real
    /// request, and a real request adds an exchange to the server's copy of the conversation (the
    /// relay might send a one-line "still there" turn with a tiny `max_tokens`). The ack therefore
    /// returns the messages the request appended, and the session appends them to its transcript,
    /// so invariant 1 (server prefix == local prefix) still holds after a ping. A relay with a
    /// genuine side-channel keep-alive returns an empty `appended`.
    func keepWarm(threadID: String, previousResponseID: String) async throws -> KeepWarmAck
}

public struct KeepWarmAck: Sendable, Equatable {
    public let responseID: String
    /// Messages the keep-warm request added to the server thread, in order.
    public let appended: [Message]

    public init(responseID: String, appended: [Message]) {
        self.responseID = responseID
        self.appended = appended
    }
}

// MARK: - Tools

public struct ToolSpec: Sendable, Equatable {
    public let name: String
    /// Side-effecting tools are executed at most once per (turn, call) — see `ToolLedger`.
    /// Read-only tools re-run on replay so they return fresh data.
    public let hasSideEffects: Bool

    public init(name: String, hasSideEffects: Bool) {
        self.name = name
        self.hasSideEffects = hasSideEffects
    }
}

public protocol ToolExecutor: Sendable {
    func spec(named name: String) -> ToolSpec?
    func execute(name: String, input: String) async throws -> String
}
