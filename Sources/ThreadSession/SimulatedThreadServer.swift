import Foundation

/// A deterministic, in-process stand-in for a relay + Messages API with message threads.
///
/// It models exactly the behaviour the session has to survive — an idle TTL measured on the
/// server's clock, eviction, head-response checks — and a TTFT that grows with uploaded tokens.
/// It does **not** call any model: replies come from a scripted responder. TTFT is computed
/// from `LatencyModel`, not measured. Used by the tests and by the demo app, which therefore
/// needs no API key and produces the same numbers on every run.
public actor SimulatedThreadServer: ThreadTransport {
    public typealias Responder = @Sendable (_ conversation: [Message], _ turn: Int) -> Message

    private struct ThreadState {
        var head: String
        var lastRequestAt: TimeInterval
        var messageCount: Int
    }

    private let clock: any SessionClock
    private let serverTTL: TimeInterval
    private let latency: LatencyModel
    private let estimator: any TokenEstimator
    private let responder: Responder
    private var threads: [String: ThreadState] = [:]
    private var conversations: [String: [Message]] = [:]
    private var counter = 0
    private var threadCounter = 0
    private var pendingFailures: [ThreadTransportError] = []

    private var log = RingBuffer<String>(capacity: 256)
    /// The most recent 256 requests, oldest first. Bounded: the demo runs this server for hours.
    public var requestLog: [String] { log.elements }

    /// The conversation the server holds for `threadID`, or `nil` if it has expired or never existed.
    public func conversation(of threadID: String) -> [Message]? {
        purgeExpired(now: clock.now())
        return conversations[threadID]
    }

    public init(
        clock: any SessionClock,
        serverTTL: TimeInterval = 300,
        latency: LatencyModel = LatencyModel(),
        estimator: any TokenEstimator = CharacterTokenEstimator(),
        responder: @escaping Responder = SimulatedThreadServer.echoResponder
    ) {
        self.clock = clock
        self.serverTTL = (serverTTL.isFinite && serverTTL > 0) ? serverTTL : 300
        self.latency = latency
        self.estimator = estimator
        self.responder = responder
    }

    /// Replies "Ack #n: <last user text>". Never calls tools.
    public static let echoResponder: Responder = { conversation, turn in
        let lastText = conversation.last(where: { $0.role == .user })?.plainText ?? ""
        return .assistant("Ack #\(turn): \(lastText.prefix(80))")
    }

    // MARK: Fault injection

    /// Drops every thread, as a server restart or memory-pressure eviction would.
    public func evictAll() {
        threads.removeAll()
        conversations.removeAll()
    }

    /// The next `send` fails with `error` before touching any state.
    /// Bounded at 16 queued failures; extra calls are ignored.
    public func failNextSend(with error: ThreadTransportError) {
        guard pendingFailures.count < 16 else { return }
        pendingFailures.append(error)
    }

    public var liveThreadCount: Int {
        purgeExpired(now: clock.now())
        return threads.count
    }

    // MARK: ThreadTransport

    public func send(_ request: ThreadRequest) async throws -> ThreadResponse {
        let now = clock.now()
        purgeExpired(now: now)
        if !pendingFailures.isEmpty {
            let e = pendingFailures.removeFirst()
            log.append("fail(\(e))")
            throw e
        }
        let threadID: String
        var conversation: [Message]
        switch request {
        case let .start(messages):
            threadCounter = Saturating.add(threadCounter, 1)
            threadID = "thr_\(threadCounter)"
            conversation = messages
            log.append("start(\(messages.count))")
        case let .continue(id, previous, newMessages):
            guard let state = threads[id], let held = conversations[id] else {
                log.append("reject-expired(\(id))")
                throw ThreadTransportError.threadExpired
            }
            guard state.head == previous else {
                log.append("reject-head(\(id))")
                throw ThreadTransportError.responseIDMismatch
            }
            threadID = id
            conversation = held + newMessages
            log.append("continue(\(id),+\(newMessages.count))")
        }
        counter = Saturating.add(counter, 1)
        let reply = responder(conversation, counter)
        conversation.append(reply)
        let responseID = "resp_\(counter)"
        threads[threadID] = ThreadState(head: responseID, lastRequestAt: now, messageCount: conversation.count)
        conversations[threadID] = conversation
        let uploaded = estimator.tokens(in: request.messages)
        return ThreadResponse(threadID: threadID, responseID: responseID, message: reply,
                              ttftMs: latency.ttftMs(uploadedTokens: uploaded))
    }

    /// Models a keep-warm as what the beta allows: a real, minimal request on the thread. It adds a
    /// two-message exchange to the server's conversation and becomes the new head.
    public func keepWarm(threadID: String, previousResponseID: String) async throws -> KeepWarmAck {
        let now = clock.now()
        purgeExpired(now: now)
        guard let state = threads[threadID], let held = conversations[threadID] else { throw ThreadTransportError.threadExpired }
        guard state.head == previousResponseID else { throw ThreadTransportError.responseIDMismatch }
        counter = Saturating.add(counter, 1)
        let responseID = "resp_\(counter)"
        let appended: [Message] = [.user("(keep-alive)"), .assistant("ok")]
        let conversation = held + appended
        threads[threadID] = ThreadState(head: responseID, lastRequestAt: now, messageCount: conversation.count)
        conversations[threadID] = conversation
        log.append("keep-warm(\(threadID))")
        return KeepWarmAck(responseID: responseID, appended: appended)
    }

    private func purgeExpired(now: TimeInterval) {
        for (id, state) in threads where now - state.lastRequestAt >= serverTTL {
            threads.removeValue(forKey: id)
            conversations.removeValue(forKey: id)
        }
    }
}
