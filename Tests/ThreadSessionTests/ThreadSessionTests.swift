import XCTest
@testable import ThreadSession

final class ThreadSessionTests: XCTestCase {
    private func make(
        clock: ManualClock = ManualClock(),
        serverClock: ManualClock? = nil,
        responder: @escaping SimulatedThreadServer.Responder = SimulatedThreadServer.echoResponder,
        tools: (any ToolExecutor)? = nil,
        keepWarm: KeepWarmPolicy = .disabled,
        maxToolRounds: Int = 8,
        telemetryCapacity: Int = 64
    ) -> (ThreadSession, SimulatedThreadServer, ManualClock) {
        let server = SimulatedThreadServer(clock: serverClock ?? clock, responder: responder)
        let session = ThreadSession(transport: server, tools: tools, clock: clock, keepWarm: keepWarm,
                                    maxToolRounds: maxToolRounds, telemetryCapacity: telemetryCapacity)
        return (session, server, clock)
    }

    // MARK: Paths

    func testFirstTurnStartsThenLiveTurnsSendOnlyTheDelta() async throws {
        let (s, server, clock) = make()
        let first = try await s.send("hello")
        XCTAssertEqual(first.paths, [.started])
        clock.advance(by: 60)
        let second = try await s.send("again")
        XCTAssertEqual(second.paths, [.delta])
        let log = await server.requestLog
        XCTAssertEqual(log, ["start(1)", "continue(thr_1,+1)"])
        let snap = await s.snapshot()
        XCTAssertEqual(snap.messages.count, 4)
        XCTAssertEqual(snap.stats.deltas, 1)
        XCTAssertEqual(snap.stats.reuploadedTokens, 0)
        XCTAssertEqual(snap.phase, .threaded)
    }

    func testAfterTheTTLTheSessionRehydratesWithAFullResendWithoutARejectedRoundTrip() async throws {
        let (s, server, clock) = make()
        _ = try await s.send("hello")
        clock.advance(by: 6 * 60)
        let phaseBefore = await s.phase
        XCTAssertEqual(phaseBefore, .expired)
        let out = try await s.send("I'm back")
        XCTAssertEqual(out.paths, [.rehydrated(.expiredLocally)])
        let log = await server.requestLog
        XCTAssertEqual(log, ["start(1)", "start(3)"], "the client knew it was dead — no wasted delta")
        let stats = await s.snapshot().stats
        XCTAssertGreaterThan(stats.reuploadedTokens, 0)
        XCTAssertEqual(stats.rejectedDeltas, 0)
    }

    /// The headline failure: the device slept, but the client measured time with a clock that
    /// pauses during sleep. It believes the thread is live; the server has dropped it.
    /// Exactly one rejected delta, then one full resend — never a loop.
    func testSleepingDeviceWithAPausingClockCostsExactlyOneRejectedRoundTrip() async throws {
        let client = ManualClock(), server = ManualClock()
        let (s, srv, _) = make(clock: client, serverClock: server)
        _ = try await s.send("hello")
        server.advance(by: 20 * 60)          // the phone was asleep for 20 minutes…
        client.advance(by: 5)                // …but the suspending clock saw 5 seconds
        let out = try await s.send("still there?")
        XCTAssertEqual(out.paths, [.rejectedDelta, .rehydrated(.serverRejected)])
        let log = await srv.requestLog
        XCTAssertEqual(log, ["start(1)", "reject-expired(thr_1)", "start(3)"])
        let snap = await s.snapshot()
        XCTAssertEqual(snap.stats.rejectedDeltas, 1)
        XCTAssertEqual(snap.stats.requests, 3)
        XCTAssertEqual(snap.messages.count, 4)
    }

    func testServerEvictionWithinTheTTLIsRecoveredTheSameWay() async throws {
        let (s, server, clock) = make()
        _ = try await s.send("one")
        await server.evictAll()
        clock.advance(by: 10)
        let out = try await s.send("two")
        XCTAssertEqual(out.paths, [.rejectedDelta, .rehydrated(.serverRejected)])
        let next = try await s.send("three")
        XCTAssertEqual(next.paths, [.delta], "the new thread is used straight away")
    }

    func testHeadMismatchIsTreatedAsARejection() async throws {
        let (s, server, _) = make()
        _ = try await s.send("one")
        await server.failNextSend(with: .responseIDMismatch)
        let out = try await s.send("two")
        XCTAssertEqual(out.paths, [.rejectedDelta, .rehydrated(.serverRejected)])
    }

    func testTwoConsecutiveRejectionsDoNotLoop() async throws {
        let (s, server, _) = make()
        _ = try await s.send("one")
        await server.failNextSend(with: .threadExpired)
        await server.failNextSend(with: .threadExpired)
        do {
            _ = try await s.send("two")
            XCTFail("expected failure")
        } catch let e as ThreadSessionError {
            XCTAssertEqual(e, .turnFailed(.threadExpired))
        }
        let log = await server.requestLog
        XCTAssertEqual(log.count, 3, "start, rejected delta, failed resend — then stop")
    }

    func testEditingHistoryForcesAFullResend() async throws {
        let (s, _, _) = make()
        _ = try await s.send("my card ends 4242")
        await s.rewrite(at: 0, with: .user("[redacted]"))
        let out = try await s.send("next")
        XCTAssertEqual(out.paths, [.rehydrated(.prefixDiverged)])
    }

    // MARK: Atomic turns

    func testAFailedTurnLeavesTheTranscriptExactlyAsBefore() async throws {
        let (s, server, _) = make()
        _ = try await s.send("one")
        let before = await s.snapshot()
        await server.failNextSend(with: .transport("offline"))
        do { _ = try await s.send("two"); XCTFail("expected failure") } catch {}
        let after = await s.snapshot()
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertEqual(after.anchor, before.anchor, "nothing past the turn start was synced, so the thread is still usable")
        let retry = try await s.send("two")
        XCTAssertEqual(retry.paths, [.delta])
    }

    func testEmptyMessageIsRejectedWithoutARequest() async throws {
        let (s, server, _) = make()
        do { _ = try await s.send("  \n"); XCTFail("expected failure") } catch let e as ThreadSessionError {
            XCTAssertEqual(e, .emptyMessage)
        }
        let log = await server.requestLog
        XCTAssertEqual(log, [])
    }

    // MARK: Tools

    /// The side effect happens, then the request carrying its result is lost. The turn rolls back
    /// and is retried; the model re-issues the same call. The reminder must be created once.
    func testSideEffectingToolRunsOnceAcrossARolledBackRetry() async throws {
        let box = ServerBox()
        let tools = CountingTools([ToolSpec(name: "create_reminder", hasSideEffects: true)]) {
            await box.server?.failNextSend(with: .transport("network handoff"))
        }
        let (s, server, _) = make(responder: Responders.tool(), tools: tools)
        await box.set(server)
        do { _ = try await s.send("remind me about standup"); XCTFail("expected failure") } catch {}
        let afterFailure = await s.snapshot()
        XCTAssertEqual(afterFailure.messages, [], "rolled back to before the user message")
        XCTAssertNil(afterFailure.anchor, "the server holds the rolled-back tool exchange, so its thread is no longer ours")
        let phaseAfterFailure = await s.phase
        XCTAssertEqual(phaseAfterFailure, .fresh)
        await box.set(nil)
        let out = try await s.send("remind me about standup")
        XCTAssertEqual(out.paths.first, .rehydrated(.rolledBack))
        XCTAssertEqual(out.reply, .assistant("Done."))
        XCTAssertEqual(out.toolsDeduplicated, 1)
        let runs = await tools.executions
        XCTAssertEqual(runs, ["create_reminder"])
    }

    /// Same scenario with a read-only tool: it *does* run again. This is what proves the single
    /// execution above comes from the ledger and not from the scenario.
    func testReadOnlyToolReRunsOnRetry() async throws {
        let box = ServerBox()
        let tools = CountingTools([ToolSpec(name: "create_reminder", hasSideEffects: false)]) {
            await box.server?.failNextSend(with: .transport("network handoff"))
        }
        let (s, server, _) = make(responder: Responders.tool(), tools: tools)
        await box.set(server)
        do { _ = try await s.send("remind me about standup"); XCTFail("expected failure") } catch {}
        await box.set(nil)
        _ = try await s.send("remind me about standup")
        let runs = await tools.executions
        XCTAssertEqual(runs, ["create_reminder", "create_reminder"])
    }

    func testSameCallInALaterTurnIsNotSuppressed() async throws {
        let tools = CountingTools([ToolSpec(name: "create_reminder", hasSideEffects: true)])
        let (s, _, _) = make(responder: Responders.tool(), tools: tools)
        _ = try await s.send("remind me about standup")
        _ = try await s.send("remind me about standup")
        let runs = await tools.executions
        XCTAssertEqual(runs.count, 2, "a new user turn is a new intent")
    }

    func testTwoIdenticalCallsInOneResponseBothRun() async throws {
        let tools = CountingTools([ToolSpec(name: "create_reminder", hasSideEffects: true)])
        let (s, _, _) = make(responder: Responders.tool(calls: 2), tools: tools)
        let out = try await s.send("remind me twice")
        XCTAssertEqual(out.toolsExecuted, 2)
        XCTAssertEqual(out.toolsDeduplicated, 0)
    }

    func testUnknownToolBecomesAnErrorResultNotACrash() async throws {
        let (s, _, _) = make(responder: Responders.tool("does_not_exist"), tools: nil)
        let out = try await s.send("remind me")
        XCTAssertEqual(out.reply, .assistant("Done."))
        let messages = await s.snapshot().messages
        XCTAssertTrue(messages.contains { $0.blocks.contains { if case .toolResult(_, _, true) = $0 { return true }; return false } })
    }

    func testToolRoundBudgetClosesOpenCallsAndKeepsTheSessionUsable() async throws {
        let tools = CountingTools([ToolSpec(name: "lookup", hasSideEffects: false)])
        let (s, server, _) = make(responder: Responders.loop, tools: tools, maxToolRounds: 2)
        let out = try await s.send("go")
        XCTAssertTrue(out.toolBudgetExhausted)
        XCTAssertEqual(out.paths.count, 3)
        let runs = await tools.executions
        XCTAssertEqual(runs.count, 2)
        let last = await s.snapshot().messages.last
        XCTAssertEqual(last?.role, .user)
        _ = try? await s.send("stop")
        let log = await server.requestLog
        XCTAssertGreaterThan(log.count, 3)
        XCTAssertEqual(log.count > 3 ? log[3] : nil, "continue(thr_1,+2)", "closing tool results ride along with the next turn's delta")
    }

    // MARK: Concurrency

    func testConcurrentSendIsRejected() async throws {
        let clock = ManualClock()
        let gate = Gate()
        let server = SimulatedThreadServer(clock: clock)
        let s = ThreadSession(transport: GatedTransport(gate: gate, inner: server), clock: clock)
        let first = Task { try await s.send("one") }
        await gate.waitForArrival()
        let dropped = await s.dropThread()
        XCTAssertFalse(dropped, "a drop during an in-flight request would be silently undone, so it is refused")
        let rewrote = await s.rewrite(at: 0, with: .user("x"))
        XCTAssertFalse(rewrote)
        do { _ = try await s.send("two"); XCTFail("expected turnInFlight") } catch let e as ThreadSessionError {
            XCTAssertEqual(e, .turnInFlight)
        }
        await gate.open()
        let out = try await first.value
        XCTAssertEqual(out.paths, [.started])
    }

    /// `reset()` runs while a turn is suspended in the transport. When the response arrives it
    /// must not be appended to the (new, empty) transcript or install an anchor.
    func testResetDuringAnAwaitDiscardsTheLateResponse() async throws {
        let clock = ManualClock()
        let gate = Gate()
        let server = SimulatedThreadServer(clock: clock)
        let s = ThreadSession(transport: GatedTransport(gate: gate, inner: server), clock: clock)
        let first = Task { try await s.send("one") }
        await gate.waitForArrival()
        await s.reset()
        await gate.open()
        do { _ = try await first.value; XCTFail("expected cancelledByReset") } catch let e as ThreadSessionError {
            XCTAssertEqual(e, .cancelledByReset)
        }
        let snap = await s.snapshot()
        XCTAssertEqual(snap.messages, [])
        XCTAssertNil(snap.anchor)
        XCTAssertEqual(snap.phase, .fresh)
    }

    // MARK: Keep-warm

    private let worthIt = KeepWarmPolicy(returnProbability: 1, dollarsPerSecondSaved: 10, maxConsecutivePings: 2)

    func testKeepWarmInTheExpiringBandExtendsTheThread() async throws {
        let (s, server, clock) = make(keepWarm: worthIt)
        _ = try await s.send(String(repeating: "x", count: 40_000))
        clock.advance(by: 240)  // 45 s left of the effective 285 s
        let d = await s.keepWarmIfWorthIt()
        XCTAssertEqual(d, .ping)
        clock.advance(by: 240)  // 480 s since the turn, 240 s since the ping
        let out = try await s.send("back")
        XCTAssertEqual(out.paths, [.delta])
        let log = await server.requestLog
        XCTAssertTrue(log.contains("keep-warm(thr_1)"))
    }

    func testWithoutKeepWarmTheSameTimelineRehydrates() async throws {
        let (s, _, clock) = make()
        _ = try await s.send(String(repeating: "x", count: 40_000))
        clock.advance(by: 240)
        let d = await s.keepWarmIfWorthIt()
        XCTAssertEqual(d, .skip(.disabled))
        clock.advance(by: 240)
        let out = try await s.send("back")
        XCTAssertEqual(out.paths, [.rehydrated(.expiredLocally)])
    }

    func testKeepWarmRespectsLifecycleAndTheConsecutiveCap() async throws {
        let (s, _, clock) = make(keepWarm: worthIt)
        _ = try await s.send(String(repeating: "x", count: 40_000))
        clock.advance(by: 240)
        await s.handle(.enteredBackground)
        let bg = await s.keepWarmIfWorthIt()
        XCTAssertEqual(bg, .skip(.backgrounded))
        await s.handle(.enteredForeground)
        await s.handle(.lowPowerMode(true))
        let lp = await s.keepWarmIfWorthIt()
        XCTAssertEqual(lp, .skip(.lowPowerMode))
        await s.handle(.lowPowerMode(false))
        let p1 = await s.keepWarmIfWorthIt(); XCTAssertEqual(p1, .ping)
        clock.advance(by: 240)
        let p2 = await s.keepWarmIfWorthIt(); XCTAssertEqual(p2, .ping)
        clock.advance(by: 240)
        let p3 = await s.keepWarmIfWorthIt()
        XCTAssertEqual(p3, .skip(.consecutiveLimit), "an idle foreground app cannot ping forever")
        _ = try await s.send("hi")
        clock.advance(by: 240)
        let p4 = await s.keepWarmIfWorthIt()
        XCTAssertEqual(p4, .ping, "a user turn refills the budget")
    }

    func testFailedKeepWarmDropsTheAnchor() async throws {
        let (s, server, clock) = make(keepWarm: worthIt)
        _ = try await s.send(String(repeating: "x", count: 40_000))
        await server.evictAll()
        clock.advance(by: 240)
        let d = await s.keepWarmIfWorthIt()
        XCTAssertEqual(d, .skip(.alreadyExpired))
        let out = try await s.send("back")
        XCTAssertEqual(out.paths, [.rehydrated(.noThread)], "no wasted delta after a failed ping")
    }

    // MARK: Phases and bounds

    func testPhaseFollowsTheClockWithoutAnyTimer() async throws {
        let (s, _, clock) = make()
        var phase = await s.phase; XCTAssertEqual(phase, .fresh)
        _ = try await s.send("hi")
        phase = await s.phase; XCTAssertEqual(phase, .threaded)
        clock.advance(by: 230)
        phase = await s.phase; XCTAssertEqual(phase, .expiring)
        clock.advance(by: 60)
        phase = await s.phase; XCTAssertEqual(phase, .expired)
        await s.dropThread()
        phase = await s.phase; XCTAssertEqual(phase, .expired)
    }

    func testTelemetryIsBounded() async throws {
        let (s, _, _) = make(telemetryCapacity: 4)
        for i in 0..<10 { _ = try await s.send("m\(i)") }
        let snap = await s.snapshot()
        XCTAssertEqual(snap.records.count, 4)
        XCTAssertEqual(snap.records.map(\.id), [6, 7, 8, 9])
        XCTAssertEqual(snap.stats.requests, 10)
    }

    // MARK: Review round 1 additions

    /// A ping is a real request that adds an exchange to the server thread. The session must
    /// mirror it, or the next delta lands on a prefix the client does not have.
    func testKeepWarmKeepsServerAndClientConversationsIdentical() async throws {
        let (s, server, clock) = make(keepWarm: worthIt)
        _ = try await s.send(String(repeating: "x", count: 40_000))
        clock.advance(by: 240)
        let d = await s.keepWarmIfWorthIt()
        XCTAssertEqual(d, .ping)
        clock.advance(by: 60)
        let out = try await s.send("after ping")
        XCTAssertEqual(out.paths, [.delta])
        let held = await server.conversation(of: "thr_1")
        let local = await s.snapshot().messages
        XCTAssertEqual(held, local, "server prefix must equal local prefix after a ping (invariant 1)")
        XCTAssertEqual(local.count, 6)
    }

    func testResetDuringAKeepWarmAwaitDiscardsTheAck() async throws {
        let clock = ManualClock()
        let gate = Gate()
        let server = SimulatedThreadServer(clock: clock)
        let s = ThreadSession(transport: GatedTransport(keepWarmGate: gate, inner: server), clock: clock, keepWarm: worthIt)
        _ = try await s.send(String(repeating: "x", count: 40_000))
        clock.advance(by: 240)
        let ping = Task { await s.keepWarmIfWorthIt() }
        await gate.waitForArrival()
        await s.reset()
        await gate.open()
        let d = await ping.value
        XCTAssertEqual(d, .skip(.cancelledByReset))
        let snap = await s.snapshot()
        XCTAssertNil(snap.anchor)
        XCTAssertEqual(snap.messages, [])
        XCTAssertEqual(snap.stats.keepWarms, 0)
    }

    func testResetDuringAFailedKeepWarmLeavesTheNewSessionAlone() async throws {
        let clock = ManualClock()
        let gate = Gate()
        let server = SimulatedThreadServer(clock: clock)
        let s = ThreadSession(transport: GatedTransport(keepWarmGate: gate, inner: server), clock: clock, keepWarm: worthIt)
        _ = try await s.send(String(repeating: "x", count: 40_000))
        clock.advance(by: 240)
        await server.evictAll()
        let ping = Task { await s.keepWarmIfWorthIt() }
        await gate.waitForArrival()
        await s.reset()
        await gate.open()
        _ = await ping.value
        let records = await s.snapshot().records
        XCTAssertEqual(records, [], "the old ping's failure must not be recorded into the reset session")
    }

    func testSendDuringAnInFlightPingIsRejectedAndPingDuringASendIsSkipped() async throws {
        let clock = ManualClock()
        let kwGate = Gate()
        let sendGate = Gate(blocking: false)
        let server = SimulatedThreadServer(clock: clock)
        let s = ThreadSession(transport: GatedTransport(gate: sendGate, keepWarmGate: kwGate, inner: server), clock: clock, keepWarm: worthIt)
        _ = try await s.send(String(repeating: "x", count: 40_000))
        clock.advance(by: 240)
        let ping = Task { await s.keepWarmIfWorthIt() }
        await kwGate.waitForArrival()
        do { _ = try await s.send("during ping"); XCTFail("expected turnInFlight") } catch let e as ThreadSessionError {
            XCTAssertEqual(e, .turnInFlight)
        }
        await kwGate.open()
        let p = await ping.value
        XCTAssertEqual(p, .ping)

        clock.advance(by: 240)
        await sendGate.close()
        let turn = Task { try await s.send("slow turn") }
        await sendGate.waitForArrival()
        let during = await s.keepWarmIfWorthIt()
        XCTAssertEqual(during, .skip(.turnInFlight))
        await sendGate.open()
        _ = try await turn.value
    }

    func testPhaseIsRehydratingWhileAFullResendOfAThreadedConversationIsInFlight() async throws {
        let clock = ManualClock()
        let gate = Gate(blocking: false)
        let server = SimulatedThreadServer(clock: clock)
        let s = ThreadSession(transport: GatedTransport(gate: gate, inner: server), clock: clock)
        _ = try await s.send("one")
        clock.advance(by: 600)
        await gate.close()
        let turn = Task { try await s.send("two") }
        await gate.waitForArrival()
        let mid = await s.phase
        XCTAssertEqual(mid, .rehydrating)
        await gate.open()
        _ = try await turn.value
        let after = await s.phase
        XCTAssertEqual(after, .threaded)
    }

    func testResetDuringAToolAwaitDiscardsTheTurnAndLeavesNoLedgerEntry() async throws {
        let gate = Gate()
        let tools = CountingTools([ToolSpec(name: "create_reminder", hasSideEffects: true)], gate: gate)
        let (s, _, _) = make(responder: Responders.tool(), tools: tools)
        let turn = Task { try await s.send("remind me") }
        await gate.waitForArrival()
        await s.reset()
        await gate.open()
        do { _ = try await turn.value; XCTFail("expected cancelledByReset") } catch let e as ThreadSessionError {
            XCTAssertEqual(e, .cancelledByReset)
        }
        let snap = await s.snapshot()
        XCTAssertEqual(snap.messages, [])
        XCTAssertEqual(snap.ledgerSize, 0)
        XCTAssertNil(snap.anchor)
    }

    /// Invariant 2 is per request: a second eviction in a later tool round of the same turn gets
    /// its own single retry instead of failing the whole turn.
    func testEvictionsInTwoRoundsOfOneTurnAreEachRecovered() async throws {
        let box = ServerBox()
        let tools = CountingTools([ToolSpec(name: "create_reminder", hasSideEffects: true)]) {
            await box.server?.evictAll()
        }
        let (s, server, _) = make(responder: Responders.tool(), tools: tools)
        _ = try await s.send("hello")
        await box.set(server)
        await server.evictAll()
        let out = try await s.send("remind me")
        XCTAssertEqual(out.paths, [.rejectedDelta, .rehydrated(.serverRejected), .rejectedDelta, .rehydrated(.serverRejected)])
        XCTAssertEqual(out.reply, .assistant("Done."))
        let runs = await tools.executions
        XCTAssertEqual(runs.count, 1)
    }

    func testResetClearsLedgerAndTelemetryButKeepsDeviceConditions() async throws {
        let tools = CountingTools([ToolSpec(name: "create_reminder", hasSideEffects: true)])
        let (s, _, _) = make(responder: Responders.tool(), tools: tools)
        _ = try await s.send("remind me")
        await s.handle(.lowPowerMode(true))
        var snap = await s.snapshot()
        XCTAssertEqual(snap.ledgerSize, 1)
        await s.reset()
        snap = await s.snapshot()
        XCTAssertEqual(snap.ledgerSize, 0)
        XCTAssertEqual(snap.records, [])
        XCTAssertEqual(snap.stats, SessionStats())
        XCTAssertTrue(snap.conditions.isLowPowerMode)
    }

    func testRewriteOutOfRangeIsRefused() async throws {
        let (s, _, _) = make()
        let empty = await s.rewrite(at: 0, with: .user("x"))
        XCTAssertFalse(empty)
        _ = try await s.send("one")
        let ok = await s.rewrite(at: 0, with: .user("ONE"))
        XCTAssertTrue(ok)
        let bad = await s.rewrite(at: 2, with: .user("x"))
        XCTAssertFalse(bad)
    }

    func testPingIsSkippedWhileLocalMessagesAreUnsynced() async throws {
        let tools = CountingTools([ToolSpec(name: "lookup", hasSideEffects: false)])
        let (s, _, clock) = make(responder: Responders.loop, tools: tools, keepWarm: worthIt, maxToolRounds: 1)
        let out = try await s.send(String(repeating: "x", count: 40_000))
        XCTAssertTrue(out.toolBudgetExhausted)
        clock.advance(by: 240)
        let d = await s.keepWarmIfWorthIt()
        XCTAssertEqual(d, .skip(.pendingLocalMessages))
    }

    // MARK: Review round 2 additions

    /// reset() during the transport await, then the server *rejects* the request. The catch path
    /// must not record into, plan for, or send on behalf of the new session.
    func testResetDuringAnAwaitThatThenFailsLeavesTheNewSessionUntouched() async throws {
        for failure in [ThreadTransportError.threadExpired, .transport("offline")] {
            let clock = ManualClock()
            let gate = Gate(blocking: false)
            let server = SimulatedThreadServer(clock: clock)
            let s = ThreadSession(transport: GatedTransport(gate: gate, inner: server), clock: clock)
            _ = try await s.send("one")
            await gate.close()
            await server.failNextSend(with: failure)
            let turn = Task { try await s.send("two") }
            await gate.waitForArrival()
            await s.reset()
            await gate.open()
            do { _ = try await turn.value; XCTFail("expected cancelledByReset") } catch let e as ThreadSessionError {
                XCTAssertEqual(e, .cancelledByReset, "\(failure)")
            }
            let snap = await s.snapshot()
            XCTAssertEqual(snap.records, [], "\(failure)")
            XCTAssertEqual(snap.messages, [], "\(failure)")
            XCTAssertNil(snap.anchor)
            let log = await server.requestLog
            XCTAssertEqual(log.count, 2, "no request may be sent for the reset session (\(failure))")
        }
    }

    func testPhaseIsStartingDuringTheFirstRequest() async throws {
        let clock = ManualClock()
        let gate = Gate()
        let server = SimulatedThreadServer(clock: clock)
        let s = ThreadSession(transport: GatedTransport(gate: gate, inner: server), clock: clock)
        let turn = Task { try await s.send("one") }
        await gate.waitForArrival()
        let mid = await s.phase
        XCTAssertEqual(mid, .starting)
        await gate.open()
        _ = try await turn.value
        let after = await s.phase
        XCTAssertEqual(after, .threaded)
    }

    func testAFailedRehydrateReturnsThePhaseToExpired() async throws {
        let (s, server, clock) = make()
        _ = try await s.send("one")
        clock.advance(by: 600)
        await server.failNextSend(with: .transport("offline"))
        do { _ = try await s.send("two"); XCTFail("expected failure") } catch {}
        let phase = await s.phase
        XCTAssertEqual(phase, .expired, "rehydrating must not stick after a failed full resend")
    }

    // MARK: Review round 3 additions

    /// Redact, then ping: the ping must be refused, and the next turn must be a full resend, so
    /// the server never keeps the unredacted text under a thread the client believes is in sync.
    func testPingAfterARedactionIsRefusedAndTheNextTurnResendsTheRedactedHistory() async throws {
        let (s, server, clock) = make(keepWarm: worthIt)
        _ = try await s.send("my card ends 4242 " + String(repeating: "x", count: 40_000))
        _ = await s.rewrite(at: 0, with: .user("[redacted]"))
        clock.advance(by: 240)
        let d = await s.keepWarmIfWorthIt()
        XCTAssertEqual(d, .skip(.prefixDiverged))
        let out = try await s.send("next")
        XCTAssertEqual(out.paths, [.rehydrated(.prefixDiverged)])
        let local = await s.snapshot()
        let held = await server.conversation(of: local.anchor?.threadID ?? "")
        XCTAssertEqual(held, local.messages)
        XCTAssertEqual(held?.first, .user("[redacted]"))
    }

    /// A tool that throws a ThreadSessionError (e.g. it drives its own sub-agent session) is a
    /// tool failure, not a reset: the turn continues with an error result and stays valid.
    func testToolThrowingAThreadSessionErrorIsAToolFailureNotACancellation() async throws {
        struct SubAgentTool: ToolExecutor {
            func spec(named name: String) -> ToolSpec? { ToolSpec(name: name, hasSideEffects: true) }
            func execute(name: String, input: String) async throws -> String { throw ThreadSessionError.turnInFlight }
        }
        let (s, _, _) = make(responder: Responders.tool(), tools: SubAgentTool())
        let out = try await s.send("remind me")
        XCTAssertEqual(out.reply, .assistant("Done."))
        let messages = await s.snapshot().messages
        XCTAssertEqual(messages.count, 4, "user, tool_use, error tool_result, final reply — no dangling tool_use")
        XCTAssertTrue(messages[2].blocks.contains { if case .toolResult(_, _, true) = $0 { return true }; return false })
    }
}

/// Late-bound reference to the server, so a tool executor created before the server can inject
/// a failure into it.
actor ServerBox {
    private(set) var server: SimulatedThreadServer?
    func set(_ s: SimulatedThreadServer?) { server = s }
}
