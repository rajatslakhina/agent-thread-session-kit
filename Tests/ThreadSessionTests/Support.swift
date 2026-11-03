import Foundation
@testable import ThreadSession

/// A digester that ignores the previous digest — i.e. *unchained*. Used to prove that prefix
/// divergence detection depends on chaining: with this digester the check must fail.
struct UnchainedDigester: TranscriptDigester {
    func digest(previous: StableDigest, message: Message) -> StableDigest {
        ChainedDigester().digest(previous: .seed, message: message)
    }
}

/// Lets a test hold a call open at an `await` and observe that it arrived there.
/// `close()` re-arms it for the next call.
actor Gate {
    private var blocking: Bool
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    init(blocking: Bool = true) { self.blocking = blocking }

    func pass() async {
        arrived += 1
        let a = arrivalWaiters
        arrivalWaiters = []
        a.forEach { $0.resume() }
        if !blocking { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForArrival() async {
        if arrived > 0 { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        blocking = false
        let w = waiting
        waiting = []
        w.forEach { $0.resume() }
    }

    func close() {
        blocking = true
        arrived = 0
    }
}

/// Gates `send` and/or `keepWarm` independently.
struct GatedTransport: ThreadTransport {
    let inner: SimulatedThreadServer
    var sendGate: Gate?
    var keepWarmGate: Gate?

    init(gate: Gate? = nil, keepWarmGate: Gate? = nil, inner: SimulatedThreadServer) {
        self.sendGate = gate
        self.keepWarmGate = keepWarmGate
        self.inner = inner
    }

    func send(_ request: ThreadRequest) async throws -> ThreadResponse {
        await sendGate?.pass()
        return try await inner.send(request)
    }
    func keepWarm(threadID: String, previousResponseID: String) async throws -> KeepWarmAck {
        await keepWarmGate?.pass()
        return try await inner.keepWarm(threadID: threadID, previousResponseID: previousResponseID)
    }
}

/// Counts real executions. `onExecute` runs inside each execution (used to inject a failure
/// into the *next* request, after the side effect has happened).
actor CountingTools: ToolExecutor {
    nonisolated let specs: [String: ToolSpec]
    private(set) var executions: [String] = []
    private let onExecute: @Sendable () async -> Void
    private let gate: Gate?

    init(_ specs: [ToolSpec], gate: Gate? = nil, onExecute: @escaping @Sendable () async -> Void = {}) {
        self.specs = Dictionary(specs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.onExecute = onExecute
        self.gate = gate
    }

    nonisolated func spec(named name: String) -> ToolSpec? { specs[name] }

    func execute(name: String, input: String) async throws -> String {
        executions.append(name)
        await gate?.pass()
        await onExecute()
        return "\(name) ok #\(executions.count)"
    }
}

enum Responders {
    /// Calls `create_reminder` (or `tool`) when the user's text contains "remind"; answers in text
    /// once a tool result is present. The tool input depends only on the conversation, so a retry
    /// re-issues the *same* call with a *different* tool_use id — like a real model would.
    static func tool(_ tool: String = "create_reminder", calls: Int = 1) -> SimulatedThreadServer.Responder {
        { conversation, turn in
            guard let last = conversation.last else { return .assistant("empty") }
            let hasResult = last.blocks.contains { if case .toolResult = $0 { return true }; return false }
            if hasResult { return .assistant("Done.") }
            if last.plainText.contains("remind") {
                let blocks = (0..<calls).map { i in
                    ContentBlock.toolUse(id: "tu_\(turn)_\(i)", name: tool, input: #"{"title":"standup"}"#)
                }
                return Message(role: .assistant, blocks: blocks)
            }
            return .assistant("Ack #\(turn)")
        }
    }

    /// Always calls a tool, forever. Exercises the tool-round budget.
    static let loop: SimulatedThreadServer.Responder = { _, turn in
        Message(role: .assistant, blocks: [.toolUse(id: "tu_\(turn)", name: "lookup", input: "{}")])
    }
}
