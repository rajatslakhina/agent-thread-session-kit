import XCTest
@testable import ThreadSession

final class PrimitivesTests: XCTestCase {
    func testSaturatingAddClampsInsteadOfTrapping() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    /// The clock the whole "continuous vs suspending" argument rests on: it must be monotonic and
    /// must actually advance with real time.
    func testContinuousSessionClockIsMonotonicAndAdvances() async throws {
        let c = ContinuousSessionClock()
        let a = c.now()
        try await Task.sleep(nanoseconds: 50_000_000)
        let b = c.now()
        XCTAssertGreaterThanOrEqual(a, 0)
        XCTAssertGreaterThanOrEqual(b - a, 0.04)
        XCTAssertLessThan(b - a, 5)
    }

    /// Compared against published FNV-1a 64 test vectors, not against a second call in the same
    /// process — the latter would also pass for a per-process-seeded `Hasher`.
    func testDigestMatchesPublishedFNV1aVectors() {
        XCTAssertEqual(StableDigest.seed.folding(Array("".utf8)).rawValue, 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableDigest.seed.folding(Array("a".utf8)).rawValue, 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableDigest.seed.folding(Array("foobar".utf8)).rawValue, 0x8594_4171_f739_67e8)
    }

    func testLengthPrefixedFieldsDoNotCollideAcrossBoundaries() {
        let a = StableDigest.seed.folding(field: "ab").folding(field: "c")
        let b = StableDigest.seed.folding(field: "a").folding(field: "bc")
        XCTAssertNotEqual(a, b)
        // Without the length prefix the raw bytes are identical, which is the bug the prefix prevents.
        XCTAssertEqual(StableDigest.seed.folding(Array("ab".utf8)).folding(Array("c".utf8)),
                       StableDigest.seed.folding(Array("a".utf8)).folding(Array("bc".utf8)))
    }

    func testDigestDescriptionIsZeroPadded() {
        XCTAssertEqual(StableDigest(rawValue: 0xab).description, "00000000000000ab")
    }

    func testManualClockIgnoresNegativeAndNonFiniteAdvances() {
        let c = ManualClock(start: 10)
        c.advance(by: -5); c.advance(by: .nan); c.advance(by: .infinity)
        XCTAssertEqual(c.now(), 10)
        c.advance(by: 2.5)
        XCTAssertEqual(c.now(), 12.5)
        XCTAssertEqual(ManualClock(start: .nan).now(), 0)
    }

    func testRingBufferKeepsNewestInOrderAndIsBounded() {
        var r = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(r.elements, [])
        for i in 1...2 { r.append(i) }
        XCTAssertEqual(r.elements, [1, 2])
        for i in 3...7 { r.append(i) }
        XCTAssertEqual(r.elements, [5, 6, 7])
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(RingBuffer<Int>(capacity: 0).capacity, 1)
        XCTAssertEqual(RingBuffer<Int>(capacity: -9).capacity, 1)
    }

    func testTokenEstimatorRoundsUpAndHandlesEmpty() {
        let e = CharacterTokenEstimator()
        XCTAssertEqual(e.tokens(in: .user("")), 0)
        XCTAssertEqual(e.tokens(in: .user("abcd")), 1)
        XCTAssertEqual(e.tokens(in: .user("abcde")), 2)
        XCTAssertEqual(CharacterTokenEstimator(charactersPerToken: 0).charactersPerToken, 1)
    }
}

final class TranscriptTests: XCTestCase {
    func testEditingAnEarlyMessageChangesEveryLaterDigest() {
        var t = Transcript()
        t.append(.user("one")); t.append(.assistant("two")); t.append(.user("three"))
        let before = t.entries.map(\.digest)
        t.rewrite(at: 0, with: .user("ONE"))
        let after = t.entries.map(\.digest)
        XCTAssertEqual(after.count, 3)
        for i in 0..<3 { XCTAssertNotEqual(before[i], after[i], "entry \(i) must re-chain") }
        XCTAssertEqual(t.messages[2], .user("three"))
    }

    func testRewriteOutOfRangeIsANoOp() {
        var t = Transcript()
        t.append(.user("x"))
        let d = t.headDigest
        t.rewrite(at: 5, with: .user("y")); t.rewrite(at: -1, with: .user("y"))
        XCTAssertEqual(t.headDigest, d)
    }

    func testPrefixDigestBoundsAndClampedAccessors() {
        var t = Transcript()
        XCTAssertEqual(t.digest(ofPrefix: 0), .seed)
        XCTAssertNil(t.digest(ofPrefix: 1))
        XCTAssertNil(t.digest(ofPrefix: -1))
        t.append(.user("a")); t.append(.assistant("b"))
        XCTAssertEqual(t.digest(ofPrefix: 2), t.headDigest)
        XCTAssertEqual(t.messages(after: -3).count, 2)
        XCTAssertEqual(t.messages(after: 1), [.assistant("b")])
        XCTAssertEqual(t.messages(after: 99), [])
        t.truncate(to: 99); XCTAssertEqual(t.count, 2)
        t.truncate(to: 1); XCTAssertEqual(t.count, 1)
        t.truncate(to: -1); XCTAssertEqual(t.count, 0)
        XCTAssertEqual(t.headDigest, .seed)
    }

    func testDigestCoversRoleAndToolErrorFlag() {
        let d = ChainedDigester()
        XCTAssertNotEqual(d.digest(previous: .seed, message: .user("hi")), d.digest(previous: .seed, message: .assistant("hi")))
        let ok = Message(role: .user, blocks: [.toolResult(toolUseID: "t", output: "o", isError: false)])
        let err = Message(role: .user, blocks: [.toolResult(toolUseID: "t", output: "o", isError: true)])
        XCTAssertNotEqual(d.digest(previous: .seed, message: ok), d.digest(previous: .seed, message: err))
    }
}

final class TTLPolicyTests: XCTestCase {
    let p = TTLPolicy(serverTTL: 300, safetyMargin: 15, expiringWindow: 60)

    func testBandsAtTheirBoundaries() {
        XCTAssertEqual(p.liveness(lastRequestAt: 0, now: 0), .live(remaining: 285))
        XCTAssertEqual(p.liveness(lastRequestAt: 0, now: 224), .live(remaining: 61))
        XCTAssertEqual(p.liveness(lastRequestAt: 0, now: 225), .expiring(remaining: 60))
        XCTAssertEqual(p.liveness(lastRequestAt: 0, now: 284), .expiring(remaining: 1))
        XCTAssertEqual(p.liveness(lastRequestAt: 0, now: 285), .expired)
        XCTAssertEqual(p.liveness(lastRequestAt: 0, now: 10_000), .expired)
    }

    func testBackwardsOrNonFiniteClockFailsTowardFullResend() {
        XCTAssertEqual(p.liveness(lastRequestAt: 100, now: 50), .expired)
        XCTAssertEqual(p.liveness(lastRequestAt: .nan, now: 50), .expired)
        XCTAssertEqual(p.liveness(lastRequestAt: 0, now: .infinity), .expired)
    }

    func testInvalidPolicyInputsAreRepaired() {
        let bad = TTLPolicy(serverTTL: -1, safetyMargin: .nan, expiringWindow: 10_000)
        XCTAssertEqual(bad.serverTTL, 300)
        XCTAssertEqual(bad.safetyMargin, 0)
        XCTAssertEqual(bad.expiringWindow, 300)
        let hugeMargin = TTLPolicy(serverTTL: 100, safetyMargin: 500, expiringWindow: -4)
        XCTAssertEqual(hugeMargin.safetyMargin, 50)
        XCTAssertEqual(hugeMargin.expiringWindow, 0)
        XCTAssertGreaterThan(hugeMargin.effectiveTTL, 0)
    }
}

final class TurnPlannerTests: XCTestCase {
    let policy = TTLPolicy()

    private func synced(_ t: Transcript, at time: TimeInterval = 0) -> ThreadAnchor {
        ThreadAnchor(threadID: "thr", lastResponseID: "r1", syncedCount: t.count, syncedDigest: t.headDigest, lastRequestAt: time)
    }

    func testNoAnchorMeansFullResend() {
        var t = Transcript(); t.append(.user("hi"))
        XCTAssertEqual(TurnPlanner.plan(anchor: nil, transcript: t, now: 0, policy: policy),
                       .fullResend(messages: [.user("hi")], reason: .noThread))
    }

    func testLiveMatchingPrefixSendsOnlyTheSuffix() {
        var t = Transcript(); t.append(.user("a")); t.append(.assistant("b"))
        let a = synced(t)
        t.append(.user("c"))
        XCTAssertEqual(TurnPlanner.plan(anchor: a, transcript: t, now: 100, policy: policy),
                       .delta(threadID: "thr", previousResponseID: "r1", newMessages: [.user("c")]))
    }

    func testExpiredByClockMeansFullResend() {
        var t = Transcript(); t.append(.user("a")); t.append(.assistant("b"))
        let a = synced(t)
        t.append(.user("c"))
        XCTAssertEqual(TurnPlanner.plan(anchor: a, transcript: t, now: 285, policy: policy),
                       .fullResend(messages: t.messages, reason: .expiredLocally))
    }

    func testEditedHistoryIsDetectedEvenWhenTheCountMatches() {
        var t = Transcript(); t.append(.user("a")); t.append(.assistant("b"))
        let a = synced(t)
        t.append(.user("c"))
        t.rewrite(at: 0, with: .user("REDACTED"))
        XCTAssertEqual(TurnPlanner.plan(anchor: a, transcript: t, now: 1, policy: policy),
                       .fullResend(messages: t.messages, reason: .prefixDiverged))
    }

    /// The guard on the claim above: with an *unchained* digester the same edit goes unnoticed,
    /// and the planner would send a delta onto a server prefix that no longer matches.
    func testDivergenceDetectionDependsOnChaining() {
        var t = Transcript(digester: UnchainedDigester())
        t.append(.user("a")); t.append(.assistant("b"))
        let a = synced(t)
        t.append(.user("c"))
        t.rewrite(at: 0, with: .user("REDACTED"))
        XCTAssertTrue(TurnPlanner.plan(anchor: a, transcript: t, now: 1, policy: policy).isDelta,
                      "an unchained digest cannot see an edit behind the anchor — chaining is load-bearing")
    }

    func testRolledBackTranscriptShorterThanServerIsDivergence() {
        var t = Transcript(); t.append(.user("a")); t.append(.assistant("b")); t.append(.user("c"))
        let a = synced(t)
        t.truncate(to: 1)
        XCTAssertEqual(TurnPlanner.plan(anchor: a, transcript: t, now: 1, policy: policy),
                       .fullResend(messages: [.user("a")], reason: .prefixDiverged))
    }
}

final class KeepWarmPolicyTests: XCTestCase {
    let expiring = TTLPolicy.Liveness.expiring(remaining: 30)

    func testGatesShortCircuitBeforeEconomics() {
        let p = KeepWarmPolicy(returnProbability: 1, dollarsPerSecondSaved: 1_000)
        XCTAssertEqual(p.decide(liveness: nil, conditions: .init(), consecutivePings: 0, contextTokens: 1, typicalDeltaTokens: 0), .skip(.noThread))
        XCTAssertEqual(p.decide(liveness: .live(remaining: 200), conditions: .init(), consecutivePings: 0, contextTokens: 1, typicalDeltaTokens: 0), .skip(.notExpiringYet))
        XCTAssertEqual(p.decide(liveness: .expired, conditions: .init(), consecutivePings: 0, contextTokens: 1, typicalDeltaTokens: 0), .skip(.alreadyExpired))
        XCTAssertEqual(p.decide(liveness: expiring, conditions: .init(isForeground: false), consecutivePings: 0, contextTokens: 1, typicalDeltaTokens: 0), .skip(.backgrounded))
        XCTAssertEqual(p.decide(liveness: expiring, conditions: .init(isLowPowerMode: true), consecutivePings: 0, contextTokens: 1, typicalDeltaTokens: 0), .skip(.lowPowerMode))
        XCTAssertEqual(p.decide(liveness: expiring, conditions: .init(isExpensiveNetwork: true), consecutivePings: 0, contextTokens: 1, typicalDeltaTokens: 0), .skip(.expensiveNetwork))
        XCTAssertEqual(p.decide(liveness: expiring, conditions: .init(), consecutivePings: 2, contextTokens: 1, typicalDeltaTokens: 0), .skip(.consecutiveLimit))
    }

    /// Break-even is independent of context size for large contexts: check both sides of it at
    /// two very different sizes.
    func testBreakEvenSeparatesPingFromSkipAtAnyLargeContext() {
        let base = KeepWarmPolicy()
        let v = base.breakEvenDollarsPerSecond
        XCTAssertEqual(v, 0.30 / (0.35 * 9), accuracy: 1e-12)
        let above = KeepWarmPolicy(dollarsPerSecondSaved: v * 1.2)
        let below = KeepWarmPolicy(dollarsPerSecondSaved: v * 0.8)
        for context in [200_000, 900_000] {
            XCTAssertEqual(above.decide(liveness: expiring, conditions: .init(), consecutivePings: 0, contextTokens: context, typicalDeltaTokens: 0), .ping)
            XCTAssertEqual(below.decide(liveness: expiring, conditions: .init(), consecutivePings: 0, contextTokens: context, typicalDeltaTokens: 0), .skip(.notWorthIt))
        }
    }

    func testDisabledAndDegenerateInputsNeverPing() {
        XCTAssertEqual(KeepWarmPolicy.disabled.breakEvenDollarsPerSecond, .infinity)
        XCTAssertEqual(KeepWarmPolicy.disabled.decide(liveness: expiring, conditions: .init(), consecutivePings: 0, contextTokens: 900_000, typicalDeltaTokens: 0), .skip(.disabled))
        XCTAssertEqual(KeepWarmPolicy(returnProbability: 0, maxConsecutivePings: 5).decide(liveness: expiring, conditions: .init(), consecutivePings: 0, contextTokens: 900_000, typicalDeltaTokens: 0), .skip(.disabled))
        let nan = KeepWarmPolicy(returnProbability: .nan, dollarsPerSecondSaved: .nan, dollarsPerMillionInputTokens: .nan, maxConsecutivePings: -3)
        XCTAssertEqual(nan.returnProbability, 0)
        XCTAssertEqual(nan.maxConsecutivePings, 0)
        XCTAssertEqual(KeepWarmPolicy(returnProbability: 7).returnProbability, 1)
        XCTAssertEqual(LatencyModel(baseMs: -1, msPerUploadedKToken: .nan).ttftMs(uploadedTokens: -50), 0)
    }
}

final class ToolLedgerTests: XCTestCase {
    func testOccurrenceCountingSeparatesRepeatedCallsInOneTurn() {
        var maker = ToolCallKeyMaker(turnDigest: .seed)
        let k1 = maker.key(name: "t", input: "{}")
        let k2 = maker.key(name: "t", input: "{}")
        let k3 = maker.key(name: "t", input: "{\"a\":1}")
        XCTAssertNotEqual(k1, k2)
        XCTAssertEqual(k1.occurrence, 1); XCTAssertEqual(k2.occurrence, 2); XCTAssertEqual(k3.occurrence, 1)
        var replay = ToolCallKeyMaker(turnDigest: .seed)
        XCTAssertEqual(replay.key(name: "t", input: "{}"), k1, "a retried attempt must reproduce the same keys")
    }

    func testLedgerIsBoundedFIFO() {
        var l = ToolLedger(capacity: 2)
        var maker = ToolCallKeyMaker(turnDigest: .seed)
        let keys = (0..<3).map { maker.key(name: "t\($0)", input: "") }
        for (i, k) in keys.enumerated() { l.record("r\(i)", for: k) }
        XCTAssertEqual(l.count, 2)
        XCTAssertNil(l.result(for: keys[0]))
        XCTAssertEqual(l.result(for: keys[2]), "r2")
        l.record("again", for: keys[2])
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(ToolLedger(capacity: 0).capacity, 1)
    }
}
