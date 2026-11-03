#if canImport(SwiftUI)
import Foundation
import SwiftUI
import ThreadSession
#if canImport(Network)
import Network
#endif

/// One step of a scripted console run (used by launch-argument scenarios in the demo app).
public enum ConsoleStep: Sendable, Equatable {
    case send(String)
    /// Time passes for both the device and the server.
    case wait(TimeInterval)
    /// The phone sleeps. The client measures it with a clock that keeps counting (correct).
    case sleepContinuousClock(TimeInterval)
    /// The phone sleeps, but the client measures time with a clock that pauses during sleep (the bug).
    case sleepPausingClock(TimeInterval)
    case enterBackground
    case enterForeground
    case keepWarmTick
    case evictServerThread
    case redactFirstMessage
    case armNetworkHandoff
    /// Re-sends the last failed turn, if any.
    case retryLastTurn
}

/// Scripted scenarios. The script is mechanism (what happens, in what order); the host app owns
/// the policies the mechanism runs under.
public enum ConsoleScripts {
    public static let names = ["pausedClock", "sleep", "keepWarm", "handoff"]

    public static func script(named name: String) -> [ConsoleStep]? {
        let opening: [ConsoleStep] = [.send("Summarize the repo"), .wait(60), .send("What changed in Auth?")]
        switch name {
        case "pausedClock": return opening + [.sleepPausingClock(1200), .send("Still there?")]
        case "sleep": return opening + [.sleepContinuousClock(1200), .send("Still there?")]
        case "keepWarm": return opening + [.wait(240), .keepWarmTick, .wait(240), .send("Next step?")]
        case "handoff": return [.send("Summarize the repo"), .armNetworkHandoff, .send("Remind me to ship the hotfix"), .retryLastTurn]
        default: return nil
        }
    }
}

/// Configuration the host app owns: policies, seed context, scripts.
public struct ConsoleConfiguration: Sendable {
    public enum ClockMode: Sendable, Equatable {
        /// Two `ManualClock`s (device and server) advanced by the time-travel controls and scripts.
        case simulated
        /// One real `ContinuousSessionClock`, fed by the real scene phase, Low Power Mode and
        /// network path. Background the app for six minutes and the thread really expires.
        /// (The Simulator cannot reproduce *system sleep*; telling a continuous clock from a
        /// suspending one needs a locked real device, or the simulated `pausedClock` scenario.)
        case live
    }

    public var clockMode: ClockMode
    /// Live mode only: send one message at launch and another every time the scene becomes active
    /// again after leaving the foreground — so a real background/lock cycle can be observed
    /// without touching the screen (used for unattended Simulator verification).
    public var liveAutopilot = false
    public var title: String
    public var ttl: TTLPolicy
    public var keepWarm: KeepWarmPolicy
    public var latency: LatencyModel
    /// Characters of "repository context" sent with the first turn, to make the conversation large
    /// enough that upload size matters (4 characters ≈ 1 token).
    public var seedContextCharacters: Int
    public var suggestedPrompts: [String]
    public var script: [ConsoleStep]

    public init(title: String, clockMode: ClockMode = .simulated, ttl: TTLPolicy = TTLPolicy(), keepWarm: KeepWarmPolicy = .disabled,
                latency: LatencyModel = LatencyModel(), seedContextCharacters: Int = 0,
                suggestedPrompts: [String] = [], script: [ConsoleStep] = []) {
        self.title = title
        self.clockMode = clockMode
        self.ttl = ttl
        self.keepWarm = keepWarm
        self.latency = latency
        self.seedContextCharacters = max(0, seedContextCharacters)
        self.suggestedPrompts = suggestedPrompts
        self.script = script
    }
}

/// A side-effecting demo tool: "creates" reminders and counts them, and can drop the connection
/// right after the side effect to show the ledger at work.
public actor ReminderTool: ToolExecutor {
    /// A count, not a list: the console can run for hours.
    public private(set) var createdCount = 0
    private var handoffArmed = false
    private let server: SimulatedThreadServer

    /// The server is passed in (not attached later) so a script's first tool call can never race
    /// an unfinished attach and silently skip the injected failure.
    public init(server: SimulatedThreadServer) { self.server = server }

    func armHandoff() { handoffArmed = true }

    public nonisolated func spec(named name: String) -> ToolSpec? {
        name == "create_reminder" ? ToolSpec(name: name, hasSideEffects: true) : nil
    }

    public func execute(name: String, input: String) async throws -> String {
        if createdCount < Int.max { createdCount += 1 }
        if handoffArmed {
            handoffArmed = false
            // The reminder exists now; the request that would report it is about to be lost.
            await server.failNextSend(with: .transport("network handoff (Wi-Fi → cellular)"))
        }
        return "Reminder #\(createdCount) created"
    }
}

@MainActor
public final class ThreadSessionConsoleModel: ObservableObject {
    @Published public private(set) var snapshot: SessionSnapshot?
    @Published public private(set) var busy = false
    @Published public private(set) var banner: String?
    @Published public private(set) var remindersCreated = 0
    @Published public private(set) var lastFailedText: String?
    @Published public var draft = ""

    public let configuration: ConsoleConfiguration
    /// Simulated mode only: the device's view of time. Advanced by every step except a pausing-clock sleep.
    private let manualClient: ManualClock?
    /// Simulated mode only: the server's view of time. Always advances.
    private let manualServer: ManualClock?
    private let server: SimulatedThreadServer
    private let tools: ReminderTool
    private let session: ThreadSession
    private static let seedMarker = "Context:"
    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    #endif

    public var isLive: Bool { configuration.clockMode == .live }

    public init(configuration: ConsoleConfiguration) {
        self.configuration = configuration
        let clientClock: any SessionClock
        let serverClock: any SessionClock
        switch configuration.clockMode {
        case .simulated:
            let c = ManualClock(), s = ManualClock()
            manualClient = c; manualServer = s
            clientClock = c; serverClock = s
        case .live:
            // One real clock for both sides: in-process, the server's wall time *is* the device's.
            let c = ContinuousSessionClock()
            manualClient = nil; manualServer = nil
            clientClock = c; serverClock = c
        }
        let server = SimulatedThreadServer(clock: serverClock, serverTTL: configuration.ttl.serverTTL,
                                           latency: configuration.latency, responder: Self.responder)
        self.server = server
        tools = ReminderTool(server: server)
        session = ThreadSession(transport: server, tools: tools, clock: clientClock,
                                ttl: configuration.ttl, keepWarm: configuration.keepWarm)
    }

    // MARK: Live lifecycle wiring

    /// Starts observing the network path (live mode only). Call once, e.g. from `.task`.
    public func startLiveObservers() async {
        guard isLive else { return }
        await session.handle(.lowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled))
        if configuration.liveAutopilot, snapshot?.messages.isEmpty ?? true { await send("Summarize the repo") }
        #if canImport(Network)
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor in await self?.networkChanged(isExpensive: expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "ThreadSessionConsole.path"))
        pathMonitor = monitor
        #endif
    }

    private var leftForeground = false
    private var backgroundedAt: Date?

    public func scenePhaseChanged(isActive: Bool) async {
        await session.handle(isActive ? .enteredForeground : .enteredBackground)
        if !isActive {
            if !leftForeground { backgroundedAt = Date() }
            leftForeground = true
        }
        if isLive { banner = isActive ? "Scene active" : "Scene left the foreground" }
        await refresh()
        if isActive, leftForeground, isLive, configuration.liveAutopilot {
            leftForeground = false
            let away = backgroundedAt.map { Self.whole(Date().timeIntervalSince($0)) } ?? 0
            await send("Back after \(away) s away")
        }
    }

    public func lowPowerModeChanged() async {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        await session.handle(.lowPowerMode(on))
        await refresh()
    }

    func networkChanged(isExpensive: Bool) async {
        await session.handle(.networkPath(isExpensive: isExpensive))
        await refresh()
    }

    /// Live mode's foreground tick: let the policy decide on a ping. Runs from a `.task` loop,
    /// which iOS suspends with the app — exactly why liveness is computed from the clock, not the loop.
    public func liveTick() async {
        guard isLive else { return }
        let d = await session.keepWarmIfWorthIt()
        if d == .ping { banner = "Keep-warm: ping sent" }
        await refresh()
    }

    /// Deterministic stand-in for the model: calls `create_reminder` when asked to remind.
    private static let responder: SimulatedThreadServer.Responder = { conversation, turn in
        guard let last = conversation.last else { return .assistant("…") }
        let isToolResult = last.blocks.contains { if case .toolResult = $0 { return true }; return false }
        if isToolResult { return .assistant("Done — \(last.plainText.replacingOccurrences(of: "← ", with: "")).") }
        let text = last.plainText.lowercased()
        if text.contains("remind") {
            return Message(role: .assistant, blocks: [.toolUse(id: "toolu_\(turn)", name: "create_reminder", input: #"{"title":"Ship the hotfix","due":"17:00"}"#)])
        }
        return .assistant("Reply #\(turn) — \(conversation.count) messages in context.")
    }

    public func refresh() async {
        snapshot = await session.snapshot()
        remindersCreated = await tools.createdCount
    }

    public func send(_ text: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var outgoing = text
        // Seed the large context only into an empty transcript (first turn, or after a rollback
        // of the first turn). A retried text already carries it.
        let transcriptEmpty = await session.snapshot().messages.isEmpty
        if transcriptEmpty, configuration.seedContextCharacters > 0, !text.hasPrefix(Self.seedMarker) {
            outgoing = Self.seedMarker + "\n" + String(repeating: "let x = 1 // ", count: configuration.seedContextCharacters / 13) + "\n\n" + text
        }
        do {
            let outcome = try await session.send(outgoing)
            lastFailedText = nil
            var parts = outcome.paths.map(\.label)
            if outcome.toolsDeduplicated > 0 { parts.append("\(outcome.toolsDeduplicated) tool call deduplicated") }
            if outcome.toolsExecuted > 0 { parts.append("\(outcome.toolsExecuted) tool call executed") }
            banner = parts.joined(separator: " → ")
        } catch let error as ThreadSessionError {
            if case .turnFailed = error { lastFailedText = outgoing }
            // A collision with an in-flight ping: give the text back instead of losing it.
            if error == .turnInFlight, draft.isEmpty { draft = text }
            banner = Self.describe(error)
        } catch {
            banner = "Failed: \(error)"
        }
        await refresh()
    }

    public func retryLastTurn() async {
        guard let text = lastFailedText else { return }
        await send(text)
    }

    public func perform(_ step: ConsoleStep) async {
        switch step {
        case let .send(text): await send(text); return
        case .retryLastTurn: await retryLastTurn(); return
        case let .wait(s):
            guard advance(client: s, server: s) else { return }
            banner = "\(Self.whole(s)) s passed"
        case let .sleepContinuousClock(s):
            guard advance(client: s, server: s) else { return }
            banner = "Slept \(Self.whole(s / 60)) min · client clock kept counting"
        case let .sleepPausingClock(s):
            guard advance(client: min(s, 5), server: s) else { return }
            banner = "Slept \(Self.whole(s / 60)) min · client clock saw ≤5 s (paused during sleep)"
        case .enterBackground: await session.handle(.enteredBackground); banner = "App backgrounded"
        case .enterForeground: await session.handle(.enteredForeground); banner = "App foregrounded"
        case .keepWarmTick:
            let d = await session.keepWarmIfWorthIt()
            banner = "Keep-warm: \(Self.describe(d))"
        case .evictServerThread: await server.evictAll(); banner = "Server evicted every thread"
        case .redactFirstMessage:
            let ok = await session.rewrite(at: 0, with: .user("[redacted by user]"))
            banner = ok ? "First message redacted locally" : "Nothing to redact (or a request is in flight)"
        case .armNetworkHandoff:
            await tools.armHandoff()
            banner = "Armed: the connection drops right after the next tool runs"
        }
        await refresh()
    }

    /// Time travel exists only in simulated mode. Returns `false` (and says so) in live mode.
    private func advance(client: TimeInterval, server: TimeInterval) -> Bool {
        guard let manualClient, let manualServer else {
            banner = "Time travel is simulated-mode only — in live mode, lock the device and wait."
            return false
        }
        manualClient.advance(by: client)
        manualServer.advance(by: server)
        return true
    }

    public func toggleLowPower() async {
        let on = !(snapshot?.conditions.isLowPowerMode ?? false)
        await session.handle(.lowPowerMode(on))
        banner = on ? "Low Power Mode on" : "Low Power Mode off"
        await refresh()
    }

    public func reset() async {
        await session.reset()
        lastFailedText = nil
        banner = "Session reset"
        await refresh()
    }

    public func runScript() async {
        for step in configuration.script { await perform(step) }
    }

    /// Whole number for display. Never traps: `ConsoleStep` durations are caller-supplied.
    static func whole(_ d: Double) -> Int {
        d.isFinite ? Int(max(-1e9, min(d, 1e9))) : 0
    }

    static func describe(_ d: KeepWarmDecision) -> String {
        switch d {
        case .ping: return "ping sent"
        case let .skip(r): return "skipped (\(r.rawValue))"
        }
    }

    static func describe(_ e: ThreadSessionError) -> String {
        switch e {
        case .turnInFlight: return "A turn is already in flight"
        case .cancelledByReset: return "Turn discarded by reset"
        case .emptyMessage: return "Type a message first"
        case let .turnFailed(t): return "Turn failed (\(t)) — transcript rolled back. Retry is safe."
        }
    }
}
#endif
