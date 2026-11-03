#if canImport(SwiftUI)
import XCTest
import ThreadSession
@testable import ThreadSessionUI

/// Turns the demo README's scenario table into checked claims: each script runs through the same
/// console model the app uses, with the same policies, and the visible outcome is asserted.
@MainActor
final class ConsoleScriptTests: XCTestCase {
    private let latency = LatencyModel(baseMs: 600, msPerUploadedKToken: 9)
    private var standard: KeepWarmPolicy { KeepWarmPolicy(returnProbability: 0.35, dollarsPerSecondSaved: 0.002, latency: latency) }
    private var premium: KeepWarmPolicy { KeepWarmPolicy(returnProbability: 0.35, dollarsPerSecondSaved: 0.15, latency: latency) }

    private func run(_ name: String, policy: KeepWarmPolicy? = nil) async throws -> ThreadSessionConsoleModel {
        let script = try XCTUnwrap(ConsoleScripts.script(named: name))
        let model = ThreadSessionConsoleModel(configuration: ConsoleConfiguration(
            title: name, ttl: TTLPolicy(serverTTL: 300, safetyMargin: 15, expiringWindow: 60),
            keepWarm: policy ?? standard, latency: latency, seedContextCharacters: 400_000, script: script))
        await model.runScript()
        return model
    }

    func testPausedClockCostsOneRejectedDeltaThenRehydrates() async throws {
        let m = try await run("pausedClock")
        XCTAssertEqual(m.banner, "delta rejected → rehydrate·serverRejected")
        XCTAssertEqual(m.snapshot?.stats.requests, 4)
        XCTAssertEqual(m.snapshot?.stats.rejectedDeltas, 1)
    }

    func testContinuousClockRehydratesWithoutAWastedRequest() async throws {
        let m = try await run("sleep")
        XCTAssertEqual(m.banner, "rehydrate·expiredLocally")
        XCTAssertEqual(m.snapshot?.stats.requests, 3)
        XCTAssertEqual(m.snapshot?.stats.rejectedDeltas, 0)
    }

    func testPremiumPolicyPingsAndTheNextTurnIsADelta() async throws {
        let m = try await run("keepWarm", policy: premium)
        XCTAssertEqual(m.snapshot?.stats.keepWarms, 1)
        XCTAssertEqual(m.banner, "delta")
        XCTAssertEqual(m.snapshot?.records.last?.path, .delta)
    }

    func testStandardPolicyDeclinesTheSamePingAndRehydrates() async throws {
        let m = try await run("keepWarm", policy: standard)
        XCTAssertEqual(m.snapshot?.stats.keepWarms, 0)
        XCTAssertEqual(m.banner, "rehydrate·expiredLocally")
    }

    func testHandoffCreatesExactlyOneReminder() async throws {
        let m = try await run("handoff")
        XCTAssertEqual(m.remindersCreated, 1)
        XCTAssertEqual(m.banner, "rehydrate·rolledBack → delta → 1 tool call deduplicated")
        XCTAssertNil(m.lastFailedText)
    }

    func testLiveModeRefusesTimeTravel() async throws {
        let m = ThreadSessionConsoleModel(configuration: ConsoleConfiguration(title: "live", clockMode: .live))
        await m.perform(.wait(600))
        XCTAssertEqual(m.banner, "Time travel is simulated-mode only — in live mode, lock the device and wait.")
        await m.send("hello")
        XCTAssertEqual(m.snapshot?.phase, .threaded)
    }

    func testUnknownScriptNameIsNil() {
        XCTAssertNil(ConsoleScripts.script(named: "nope"))
        for name in ConsoleScripts.names { XCTAssertNotNil(ConsoleScripts.script(named: name)) }
    }
}
#endif
