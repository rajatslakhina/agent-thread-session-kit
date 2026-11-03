import Foundation

/// The user-visible lifecycle of the server thread, derived — never stored — from the anchor,
/// the clock and whether a rehydrating request is in flight.
public enum SessionPhase: String, Sendable, Equatable {
    /// `starting`: the very first request of a conversation is in flight.
    case fresh, starting, threaded, expiring, expired, rehydrating
}

public enum LifecycleEvent: Sendable, Equatable {
    case enteredBackground
    case enteredForeground
    case lowPowerMode(Bool)
    case networkPath(isExpensive: Bool)
}

public enum ThreadSessionError: Error, Sendable, Equatable {
    /// One turn at a time. Concurrent sends are rejected rather than queued: an agent turn is a
    /// read-modify-write of the transcript, and silently queuing it hides UI bugs.
    case turnInFlight
    /// `reset()` ran while this turn was suspended at an `await`; its result was discarded.
    case cancelledByReset
    case emptyMessage
    /// The turn failed and the transcript was rolled back to before the user message.
    case turnFailed(ThreadTransportError)
}

public struct TurnOutcome: Sendable, Equatable {
    public let reply: Message
    public let paths: [TurnPath]
    public let toolsExecuted: Int
    public let toolsDeduplicated: Int
    /// `true` when the agent loop hit `maxToolRounds` and the session closed the open tool calls
    /// with error results instead of continuing.
    public let toolBudgetExhausted: Bool
}

public struct SessionStats: Sendable, Equatable {
    public var requests = 0
    public var deltas = 0
    public var fullResends = 0
    public var rejectedDeltas = 0
    public var keepWarms = 0
    public var uploadedTokens = 0
    /// Tokens re-uploaded by full resends of a conversation that had already been threaded —
    /// the cost the TTL imposes on a mobile client.
    public var reuploadedTokens = 0
}

public struct SessionSnapshot: Sendable, Equatable {
    public let phase: SessionPhase
    public let messages: [Message]
    public let anchor: ThreadAnchor?
    public let liveness: TTLPolicy.Liveness?
    public let records: [TurnRecord]
    public let stats: SessionStats
    public let conditions: DeviceConditions
    public let keepWarm: KeepWarmDecision
    public let contextTokens: Int
    public let ledgerSize: Int
}

/// A lifecycle-aware session over a server-side message thread.
///
/// Invariants (each has a test):
/// 1. A delta is sent only if the server's prefix equals the local prefix (chained digest).
/// 2. A server rejection of a delta costs at most **one** extra request *per request*: the retry
///    is a full resend, which starts a new thread and cannot be rejected as expired.
/// 3. A failed turn leaves the transcript exactly as it was before the turn.
/// 4. A side-effecting tool call runs at most once per (turn, call), across retries.
/// 5. State written after an `await` is discarded if `reset()` ran during the suspension.
/// 6. The session's memory is bounded apart from the transcript itself: telemetry is a ring
///    buffer and the tool ledger has a capacity.
/// 7. A keep-warm never desynchronises the prefixes: its exchange is mirrored, and it is
///    refused while local messages are unsynced or the synced prefix has been rewritten.
public actor ThreadSession {
    private let transport: any ThreadTransport
    private let tools: (any ToolExecutor)?
    private let clock: any SessionClock
    public let ttl: TTLPolicy
    public let keepWarmPolicy: KeepWarmPolicy
    private let estimator: any TokenEstimator
    private let maxToolRounds: Int

    private var transcript: Transcript
    private var anchor: ThreadAnchor?
    private var ledger: ToolLedger
    private var records: RingBuffer<TurnRecord>
    private var stats = SessionStats()
    private var conditions = DeviceConditions()
    private var consecutivePings = 0
    private var inFlight = false
    private var rehydrating = false
    private var everThreaded = false
    /// Set when a failed turn dropped the anchor; labels the next full resend `.rolledBack`.
    private var rolledBack = false
    private var epoch = 0
    private var nextRecordID = 0
    private var lastDeltaTokens = 0

    public init(
        transport: any ThreadTransport,
        tools: (any ToolExecutor)? = nil,
        clock: any SessionClock = ContinuousSessionClock(),
        ttl: TTLPolicy = TTLPolicy(),
        keepWarm: KeepWarmPolicy = .disabled,
        estimator: any TokenEstimator = CharacterTokenEstimator(),
        digester: any TranscriptDigester = ChainedDigester(),
        maxToolRounds: Int = 8,
        telemetryCapacity: Int = 64,
        ledgerCapacity: Int = 256
    ) {
        self.transport = transport
        self.tools = tools
        self.clock = clock
        self.ttl = ttl
        self.keepWarmPolicy = keepWarm
        self.estimator = estimator
        self.maxToolRounds = max(1, maxToolRounds)
        self.transcript = Transcript(digester: digester)
        self.ledger = ToolLedger(capacity: ledgerCapacity)
        self.records = RingBuffer(capacity: telemetryCapacity)
    }

    // MARK: Lifecycle

    /// Records a lifecycle change. Note what this does *not* do: it never starts a timer. iOS
    /// suspends timers with the app, so liveness is always recomputed from the clock on demand.
    public func handle(_ event: LifecycleEvent) {
        switch event {
        case .enteredBackground: conditions.isForeground = false
        case .enteredForeground: conditions.isForeground = true
        case let .lowPowerMode(on): conditions.isLowPowerMode = on
        case let .networkPath(expensive): conditions.isExpensiveNetwork = expensive
        }
    }

    /// Clears the conversation, the thread, the ledger and the telemetry. Device conditions are
    /// kept: they describe the phone, not the session. Any turn or ping suspended at an `await`
    /// discards its result.
    public func reset() {
        epoch &+= 1   // wrapping is fine: only equality with a captured value matters
        transcript.truncate(to: 0)
        records = RingBuffer(capacity: records.capacity)
        stats = SessionStats()
        anchor = nil
        ledger.removeAll()
        consecutivePings = 0
        rehydrating = false
        everThreaded = false
        rolledBack = false
        lastDeltaTokens = 0
    }

    /// Forgets the server thread without touching history (e.g. after an account switch).
    /// Refused while a request is in flight — its response would install a new anchor and silently
    /// undo the drop. Returns whether the thread was dropped.
    @discardableResult
    public func dropThread() -> Bool {
        guard !inFlight else { return false }
        anchor = nil
        return true
    }

    /// Rewrites a past message (an edit or a redaction). The next turn will be a full resend.
    /// Refused while a request is in flight, or when `index` is out of range.
    @discardableResult
    public func rewrite(at index: Int, with message: Message) -> Bool {
        guard !inFlight, index >= 0, index < transcript.count else { return false }
        transcript.rewrite(at: index, with: message)
        return true
    }

    // MARK: Reads

    public var phase: SessionPhase {
        if rehydrating { return .rehydrating }
        guard let anchor else {
            if inFlight && !everThreaded { return .starting }
            return transcript.isEmpty ? .fresh : .expired
        }
        switch ttl.liveness(lastRequestAt: anchor.lastRequestAt, now: clock.now()) {
        case .live: return .threaded
        case .expiring: return .expiring
        case .expired: return .expired
        }
    }

    public func snapshot() -> SessionSnapshot {
        let liveness = anchor.map { ttl.liveness(lastRequestAt: $0.lastRequestAt, now: clock.now()) }
        return SessionSnapshot(
            phase: phase,
            messages: transcript.messages,
            anchor: anchor,
            liveness: liveness,
            records: records.elements,
            stats: stats,
            conditions: conditions,
            keepWarm: keepWarmDecision(liveness: liveness),
            contextTokens: estimator.tokens(in: transcript.messages),
            ledgerSize: ledger.count
        )
    }

    // MARK: Keep-warm

    private func keepWarmDecision(liveness: TTLPolicy.Liveness?) -> KeepWarmDecision {
        if inFlight { return .skip(.turnInFlight) }
        return keepWarmPolicy.decide(
            liveness: liveness,
            conditions: conditions,
            consecutivePings: consecutivePings,
            contextTokens: estimator.tokens(in: transcript.messages),
            typicalDeltaTokens: lastDeltaTokens
        )
    }

    /// Evaluates the keep-warm policy and pings if it says so. Call from a foreground timer;
    /// calling it while backgrounded is harmless (the policy declines).
    @discardableResult
    public func keepWarmIfWorthIt() async -> KeepWarmDecision {
        guard let current = anchor else { return .skip(.noThread) }
        let decision = keepWarmDecision(liveness: ttl.liveness(lastRequestAt: current.lastRequestAt, now: clock.now()))
        guard decision == .ping else { return decision }
        guard transcript.count == current.syncedCount else { return .skip(.pendingLocalMessages) }
        // A rewrite/redaction keeps the count but changes the prefix. Pinging would extend the
        // server's *old* conversation and then re-anchor on the new local digest — a silent desync.
        guard transcript.digest(ofPrefix: current.syncedCount) == current.syncedDigest else { return .skip(.prefixDiverged) }

        let myEpoch = epoch
        let sentAt = clock.now()
        let context = estimator.tokens(in: transcript.messages)
        inFlight = true
        defer { inFlight = false }
        do {
            let ack = try await transport.keepWarm(threadID: current.threadID, previousResponseID: current.lastResponseID)
            // Re-validate after the suspension: reset() may have run, or the anchor may have moved.
            // (`anchor == current` alone would also catch a reset, which nils the anchor; the epoch
            // check states the intent and covers a reset followed by a new thread.)
            guard epoch == myEpoch, anchor == current else { return .skip(.cancelledByReset) }
            // The ping was a real request: mirror what it added, so the prefixes still match.
            for message in ack.appended { transcript.append(message) }
            anchor = ThreadAnchor(threadID: current.threadID, lastResponseID: ack.responseID, syncedCount: transcript.count,
                                  syncedDigest: transcript.headDigest, lastRequestAt: sentAt)
            consecutivePings = Saturating.add(consecutivePings, 1)
            stats.keepWarms = Saturating.add(stats.keepWarms, 1)
            stats.requests = Saturating.add(stats.requests, 1)
            let pingUploaded = estimator.tokens(in: ack.appended.filter { $0.role == .user })
            record(.keepWarm, uploaded: pingUploaded, context: context, ttft: nil, at: sentAt)
            return .ping
        } catch {
            guard epoch == myEpoch else { return .skip(.cancelledByReset) }
            // A failed ping means we cannot vouch for the thread any more.
            if anchor == current { anchor = nil }
            stats.requests = Saturating.add(stats.requests, 1)
            record(.failed, uploaded: 0, context: context, ttft: nil, at: sentAt)
            return .skip(.alreadyExpired)
        }
    }

    // MARK: Turns

    public func send(_ text: String) async throws -> TurnOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ThreadSessionError.emptyMessage }
        guard !inFlight else { throw ThreadSessionError.turnInFlight }
        inFlight = true
        defer {
            inFlight = false
            rehydrating = false
        }

        let myEpoch = epoch
        let startCount = transcript.count
        let turnDigest = transcript.append(.user(text)).digest
        var keyMaker = ToolCallKeyMaker(turnDigest: turnDigest)
        var paths: [TurnPath] = []
        var executed = 0
        var deduped = 0
        var rounds = 0
        var retriedRejection = false
        consecutivePings = 0   // the user is active again; the ping budget refills

        while true {
            let now = clock.now()
            var plan = TurnPlanner.plan(anchor: anchor, transcript: transcript, now: now, policy: ttl)
            if case let .fullResend(messages, .noThread) = plan {
                if retriedRejection { plan = .fullResend(messages: messages, reason: .serverRejected) }
                else if rolledBack { plan = .fullResend(messages: messages, reason: .rolledBack) }
            }
            let request: ThreadRequest
            let path: TurnPath
            switch plan {
            case let .delta(threadID, previousResponseID, newMessages):
                request = .continue(threadID: threadID, previousResponseID: previousResponseID, newMessages: newMessages)
                path = .delta
            case let .fullResend(messages, reason):
                request = .start(messages: messages)
                path = (everThreaded || reason == .serverRejected || reason == .rolledBack) ? .rehydrated(reason) : .started
                rehydrating = everThreaded
            }
            let uploaded = estimator.tokens(in: request.messages)
            let context = estimator.tokens(in: transcript.messages)

            let response: ThreadResponse
            do {
                response = try await transport.send(request)
            } catch {
                guard epoch == myEpoch else { throw ThreadSessionError.cancelledByReset }
                let transportError = (error as? ThreadTransportError) ?? .transport(String(describing: error))
                if plan.isDelta, !retriedRejection,
                   transportError == .threadExpired || transportError == .responseIDMismatch {
                    // Invariant 2: exactly one fallback. The next plan has no anchor, so it is a
                    // full resend, which starts a new thread and cannot be rejected as expired.
                    retriedRejection = true
                    anchor = nil
                    stats.rejectedDeltas = Saturating.add(stats.rejectedDeltas, 1)
                    stats.requests = Saturating.add(stats.requests, 1)
                    record(.rejectedDelta, uploaded: uploaded, context: context, ttft: nil, at: now)
                    paths.append(.rejectedDelta)
                    continue
                }
                // Invariant 3: atomic turn. Roll back; keep the ledger (the world is not rolled back).
                transcript.truncate(to: startCount)
                if let a = anchor, a.syncedCount > startCount {
                    // The server holds messages we just rolled back: its prefix is no longer ours.
                    anchor = nil
                    rolledBack = true
                }
                stats.requests = Saturating.add(stats.requests, 1)
                record(.failed, uploaded: uploaded, context: context, ttft: nil, at: now)
                throw ThreadSessionError.turnFailed(transportError)
            }
            // Invariant 5: reset() ran while we were suspended — the transcript we would append to is gone.
            guard epoch == myEpoch else { throw ThreadSessionError.cancelledByReset }

            transcript.append(response.message)
            anchor = ThreadAnchor(threadID: response.threadID, lastResponseID: response.responseID,
                                  syncedCount: transcript.count, syncedDigest: transcript.headDigest, lastRequestAt: now)
            everThreaded = true
            rehydrating = false
            rolledBack = false
            // The one-retry budget is per request: a later tool round gets its own.
            retriedRejection = false
            stats.requests = Saturating.add(stats.requests, 1)
            stats.uploadedTokens = Saturating.add(stats.uploadedTokens, uploaded)
            switch path {
            case .delta:
                stats.deltas = Saturating.add(stats.deltas, 1)
                lastDeltaTokens = uploaded
            case .rehydrated:
                stats.fullResends = Saturating.add(stats.fullResends, 1)
                stats.reuploadedTokens = Saturating.add(stats.reuploadedTokens, uploaded)
            default:
                stats.fullResends = Saturating.add(stats.fullResends, 1)
            }
            record(path, uploaded: uploaded, context: context, ttft: response.ttftMs, at: now)
            paths.append(path)

            let calls = response.message.toolUses
            if calls.isEmpty {
                return TurnOutcome(reply: response.message, paths: paths, toolsExecuted: executed,
                                   toolsDeduplicated: deduped, toolBudgetExhausted: false)
            }

            rounds = Saturating.add(rounds, 1)
            if rounds > maxToolRounds {
                // Close every open tool_use so the transcript stays a valid conversation; the
                // closing message goes up as part of the next turn's delta.
                let closing = calls.map { ContentBlock.toolResult(toolUseID: $0.id, output: "Tool budget exhausted for this turn.", isError: true) }
                transcript.append(Message(role: .user, blocks: closing))
                return TurnOutcome(reply: response.message, paths: paths, toolsExecuted: executed,
                                   toolsDeduplicated: deduped, toolBudgetExhausted: true)
            }

            var results: [ContentBlock] = []
            for call in calls {
                let spec = tools?.spec(named: call.name)
                guard let tools, let spec else {
                    results.append(.toolResult(toolUseID: call.id, output: "Unknown tool \(call.name).", isError: true))
                    continue
                }
                let key = keyMaker.key(name: call.name, input: call.input)
                if spec.hasSideEffects, let cached = ledger.result(for: key) {
                    deduped = Saturating.add(deduped, 1)
                    results.append(.toolResult(toolUseID: call.id, output: cached, isError: false))
                    continue
                }
                do {
                    let output = try await tools.execute(name: call.name, input: call.input)
                    // reset() during the tool's await already cleared the ledger and the transcript;
                    // recording into the new session would leak a key across sessions.
                    if spec.hasSideEffects, epoch == myEpoch { ledger.record(output, for: key) }
                    guard epoch == myEpoch else { throw ThreadSessionError.cancelledByReset }
                    executed = Saturating.add(executed, 1)
                    results.append(.toolResult(toolUseID: call.id, output: output, isError: false))
                } catch {
                    // Decide by epoch, not by error type: a tool may itself drive another session
                    // and throw that session's ThreadSessionError, which is just a tool failure here.
                    guard epoch == myEpoch else { throw ThreadSessionError.cancelledByReset }
                    results.append(.toolResult(toolUseID: call.id, output: "Tool failed: \(error)", isError: true))
                }
            }
            transcript.append(Message(role: .user, blocks: results))
        }
    }

    private func record(_ path: TurnPath, uploaded: Int, context: Int, ttft: Double?, at: TimeInterval) {
        records.append(TurnRecord(id: nextRecordID, path: path, uploadedTokens: uploaded, contextTokens: context, ttftMs: ttft, at: at))
        nextRecordID = Saturating.add(nextRecordID, 1)
    }
}
