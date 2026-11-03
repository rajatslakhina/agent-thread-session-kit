# ThreadSessionKit

**Your phone sleeps longer than the thread lives.** A lifecycle-aware session layer for long-running Claude agent features on iOS, built for the Messages API's new *message threads*.

![Swift 6](https://img.shields.io/badge/Swift-6.0-orange) ![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20·%20macOS%2014%20·%20Linux%20(core)-blue) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

[![CI](https://github.com/rajatslakhina/agent-thread-session-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/agent-thread-session-kit/actions/workflows/ci.yml)

**Demo app:** [agent-thread-session-demo-app](https://github.com/rajatslakhina/agent-thread-session-demo-app) — an iOS app that consumes this package from GitHub (pinned to 1.0.0) and runs it through sleep, a paused clock, keep-warm, eviction and a network handoff.

---

## The problem

On 2 Nov 2026 Anthropic put [message threads](https://claude.com/resources/articles/message-threads) into public beta. You add a `thread` parameter. The first request carries the whole conversation; every later request carries only the new messages plus the previous response's ID. The server holds the thread in memory and **expires it 5 minutes after the last request**. Anthropic reports about 35% lower median time to first token on 500k–1M-token requests. Token usage does not change, because Claude still reads the whole conversation every turn.

That design suits a coding agent running in a terminal. An iPhone app is a different environment:

| What iOS does | What it does to a 5-minute thread |
|---|---|
| The user locks the phone for 20 minutes | The thread is gone. A delta sent on wake is rejected. |
| The app measures elapsed time with a clock that **pauses during sleep** (`SuspendingClock`, `mach_absolute_time`, `DispatchTime`) | The client thinks 5 seconds passed and sends a delta to a dead thread. |
| A `Timer` was meant to refresh the thread | Timers don't fire while the app is suspended. |
| Wi-Fi hands off to cellular mid-turn, *after* a tool ran | A naive retry re-runs the side effect (two reminders, two payments). |
| The user edits or redacts an earlier message | The server's prefix no longer matches yours. A delta is now *wrong*, not just slow. |
| "Keep the thread warm" sounds free | It isn't. The beta has no keep-alive, so a ping is a real request: Claude reads the whole context (you pay for every token) and the exchange lands in the thread. |

The 35% headline applies only to one path, the live delta. A mobile client spends a large share of its turns on the other paths. This library makes those paths explicit, correct and measurable.

## Why this matters (the lead's view)

This is a platform decision, not a feature. Every team shipping an agent feature on top of threads will meet the same six failure modes. If each team solves them alone you get five keep-alive timers, three retry loops and one duplicated payment. One session layer gives the org:

- **One correctness rule.** The local, content-addressed transcript is the source of truth. The server thread is a cache of it. Anything the cache loses is rebuilt deterministically.
- **One cost rule.** Keep-warm is an explicit economic decision with a break-even you can put in a design review, not a timer someone added.
- **One dashboard dimension.** Every request is tagged `start / delta / rehydrate·<reason> / delta rejected / keep-warm`, with uploaded tokens and TTFT, so "is threads actually faster for *our* users?" has an answer.

## Architecture

```
 SwiftUI / feature code
        │  send(text) · handle(LifecycleEvent) · keepWarmIfWorthIt()
        ▼
 ┌──────────────── ThreadSession (actor) ────────────────┐
 │  Transcript ── chained FNV-1a digests (source of truth)│
 │  TurnPlanner ─ pure: delta | fullResend(reason)        │
 │  TTLPolicy ─── pure: live | expiring | expired          │
 │  KeepWarmPolicy pure: ping | skip(reason)               │
 │  ToolLedger ── at-most-once side effects across retries │
 │  RingBuffer<TurnRecord> ─ bounded telemetry             │
 └───────────────────────────┬───────────────────────────┘
                             │ ThreadTransport (protocol)
                             ▼
        your backend-for-frontend relay  ──►  Messages API (thread=…)
        (owns the API key + beta wire format)
```

`fresh → starting → threaded → expiring → expired → rehydrating` is a *derived* phase: it's computed from the anchor, the clock and whether a rehydrating request is in flight. It is never stored, so there's no timer that can be wrong.

| Module | Contents | Platforms |
|---|---|---|
| `ThreadSession` | Session actor, planner, policies, ledger, telemetry, `SimulatedThreadServer` | iOS, macOS, Linux |
| `ThreadSessionUI` | `ThreadSessionConsole` (SwiftUI), its model, the scenario scripts. Two clock modes: *simulated* (two `ManualClock`s, time travel) and *live* (`ContinuousSessionClock` fed by the real `scenePhase`, Low Power Mode notification and `NWPathMonitor.isExpensive`) | iOS, macOS (compiles to an empty module elsewhere) |

## Invariants (each one has a test)

1. **A delta is sent only if the server's prefix equals the local prefix.** Every transcript entry's digest commits to the whole prefix before it. `testDivergenceDetectionDependsOnChaining` swaps in an *unchained* digester and asserts the check then **misses** an edit. That proves chaining is what makes the check work.
2. **A rejected delta costs at most one extra request, per request.** The single retry is a full resend, which starts a new thread. The budget resets after every successful response, so a second eviction in a later tool round of the same turn is recovered too. `testSleepingDeviceWithAPausingClockCostsExactlyOneRejectedRoundTrip`, `testTwoConsecutiveRejectionsDoNotLoop`, `testEvictionsInTwoRoundsOfOneTurnAreEachRecovered`.
3. **A failed turn leaves the transcript exactly as it was.** A transcript that ends in an unanswered `tool_use` isn't a valid conversation, so turns are atomic. A tool that throws, even a `ThreadSessionError` from a sub-agent session it drives, becomes an error `tool_result`. It is never mistaken for this session's cancellation (`testToolThrowingAThreadSessionErrorIsAToolFailureNotACancellation`).
4. **A side-effecting tool call runs at most once per (turn, call), across retries.** `testSideEffectingToolRunsOnceAcrossARolledBackRetry` runs the scenario. Its control, `testReadOnlyToolReRunsOnRetry`, runs the identical scenario with a read-only tool and shows two executions. So the single execution comes from the ledger, not from the scenario.
5. **State written after an `await` is discarded if `reset()` ran during the suspension.** The gated tests cover all three suspension points: the transport `send`, the keep-warm request (success and failure) and the tool execution. Calls that would be silently undone by an in-flight response (`dropThread`, `rewrite`) are refused and return `false`. A ping during a turn is skipped, and a turn during a ping is rejected.
6. **The session's memory is bounded apart from the transcript itself.** Telemetry is a ring buffer, and the tool ledger has a capacity. The simulator's request log is a ring buffer too.
7. **A keep-warm never desynchronises the prefixes.** Its exchange is mirrored, and a ping is refused while local messages are unsynced (`.pendingLocalMessages`) or the synced prefix has been rewritten (`.prefixDiverged`, e.g. after a redaction). `testKeepWarmKeepsServerAndClientConversationsIdentical` and `testPingAfterARedactionIsRefusedAndTheNextTurnResendsTheRedactedHistory` compare the simulator's copy of the conversation with the client's.

## Design decisions and trade-offs

**Continuous clock, not suspending.** The TTL is wall time on the server. `ContinuousSessionClock` uses `ContinuousClock`, which keeps counting through system sleep. *Rejected:* `SuspendingClock` / `DispatchTime`. They under-report sleep and cause the exact failure the demo's "paused clock" scenario shows.

**Measure TTL from send time, minus a safety margin.** The server's 5 minutes start when the request *arrives*. Measuring from when we *sent* it, with a 15 s margin, errs early. An early full resend costs upload time. A late delta costs a rejected round trip plus the upload time anyway.

**Fail toward full resend.** A backwards clock, a NaN reading, a count mismatch or a digest mismatch all fall back to a full resend. A full resend is always correct; a delta is only sometimes correct.

**Chained FNV-1a, not `Hasher`, not SHA-256.** `Hasher` is seeded per process, so digests would change on every launch. The test checks published FNV-1a vectors rather than comparing two calls in one process, because two in-process calls would also match for `Hasher`. SHA-256 means CryptoKit (not on Linux) or a swift-crypto dependency. *Trade-off:* FNV-1a is for identity, not security. The app is the only writer of its transcript.

**Atomic turns + a ledger that outlives rollback.** When a rollback removes messages the server had already received, the anchor is dropped and the next full resend is labelled `rehydrate·rolledBack`, so the dashboard can tell it apart from an expiry. Rolling back the transcript doesn't roll back the world. A ledger key is `(digest of the turn's user message on its prefix, tool name, input digest, occurrence)`. A retried turn reproduces the same keys. A different message, or the same message later in the conversation, gets new keys. Two identical calls in one response stay distinct (`occurrence`). Read-only tools always re-run, so they return fresh data. *Rejected:* keying by `tool_use.id`. A regenerated response has new IDs, so that would never deduplicate. *Trade-off:* tool inputs are digested verbatim. Two semantically equal JSON inputs with different key order count as different calls.

**Keep-warm is a real request, so it is mirrored.** The beta exposes no keep-alive; a thread is refreshed only by a request, and a request adds an exchange to the server's conversation. So `ThreadTransport.keepWarm` returns a `KeepWarmAck` with the messages it appended. The session appends them to its transcript, which keeps invariant 1 intact. It also refuses to ping while there are local messages the server hasn't seen (`.pendingLocalMessages`), since the ping would otherwise land on the server *before* them. A relay with a side-channel keep-alive returns an empty `appended`. *Rejected:* a TTL-only "touch". The beta does not offer one, and the first version of this library assumed it, which broke invariant 1 against a real thread.

**Keep-warm is priced, gated and capped.** The policy pings only when `P(return) × latency saved × value of a second > context tokens × input price`. Both sides grow linearly with context, so context size cancels out. Break-even depends only on price, upload latency and return probability. With the defaults it comes to `$0.30 / (0.35 × 9 ms/k-token) ≈ $0.095` per saved second. Device gates (background, Low Power Mode, expensive network) and a consecutive-ping cap come before the economics, so an idle foregrounded app can't spend forever. `KeepWarmPolicy.disabled` is the default until a team has measured something (it reports `.skip(.disabled)`). *Trade-off the formula leaves out:* every ping permanently adds an exchange to the conversation. The model sees it, and every later rehydrate re-uploads it. The formula also ignores the ping's output tokens. Both make real pings slightly more expensive than modelled, which is one more reason the default is off.

**Reject concurrent sends instead of queuing them.** A turn is a read-modify-write of the transcript. Queuing hides double-tap bugs. *Trade-off:* a send that collides with a background keep-warm gets `.turnInFlight`, and the UI must retry it.

**The wire format lives in the relay.** `ThreadTransport` speaks `start(messages)` / `continue(threadID, previousResponseID, newMessages)`. The beta's JSON field names stay in your backend-for-frontend, along with the API key. That way a beta change ships without an App Store release. *Not built here:* the relay itself. `SimulatedThreadServer` stands in for it.

## Usage

```swift
import ThreadSession

let session = ThreadSession(
    transport: MyRelayTransport(),            // conforms to ThreadTransport
    tools: MyTools(),                         // ToolSpec(hasSideEffects:) per tool
    ttl: TTLPolicy(serverTTL: 300, safetyMargin: 15),
    keepWarm: .disabled                       // until you've measured the break-even
)

// Scene phase → lifecycle. No timers. (ThreadSessionUI's live mode shows the full wiring:
// scenePhase, NSProcessInfoPowerStateDidChange, NWPathMonitor.)
await session.handle(.enteredBackground)
await session.handle(.lowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled))

let outcome = try await session.send("Refactor the auth module")
outcome.paths            // [.delta]  or  [.rejectedDelta, .rehydrated(.serverRejected)]
await session.snapshot() // phase, liveness, per-request telemetry, stats
```

```swift
// Package.swift
.package(url: "https://github.com/rajatslakhina/agent-thread-session-kit.git", from: "1.0.0")
```

## Verification

- **Linux (Swift 6.0.3, x86_64):** clean build (`rm -rf .build`) with `-warnings-as-errors`: 0 warnings. `swift test`: **64 tests, 0 failures**. The UI test target compiles to nothing on Linux.
- **macOS (Xcode 27.2):** clean `swift test -Xswiftc -warnings-as-errors`: **64 core + 7 console-script tests, 0 failures**. The console-script tests run each demo scenario through the same console model the app uses and assert its banner and counters. `xcodebuild build -scheme ThreadSessionKit-Package -destination 'generic/platform=iOS Simulator'` with warnings as errors: **BUILD SUCCEEDED**.
- **Mutation checks:** `scripts/mutation-check.sh` applies 15 deliberate breakages to a scratch copy. It first checks that each one compiles, then requires the test suite to fail. All 15 are caught:
  - no ledger dedupe;
  - no post-`await` guard on send (success and failure paths), keep-warm or tool execution;
  - keep-warm ack not mirrored;
  - ping allowed during a turn;
  - `dropThread` allowed in flight;
  - retry budget per turn instead of per request;
  - `reset` keeping the ledger;
  - digest check reduced to a count check;
  - no rollback on failure;
  - anchor kept after a rollback;
  - `rehydrating` sticking after a failed turn;
  - ping allowed on a rewritten (redacted) prefix.
- **Simulator:** see the demo repo. The app ran on an iPhone Duo Simulator (iOS 27.2) in four scripted scenarios plus a live background cycle. After publishing, the unmodified demo project resolved this package from GitHub at 1.0.0, built, and ran the `handoff` scenario on the Simulator.
- **CI ([Actions](https://github.com/rajatslakhina/agent-thread-session-kit/actions/workflows/ci.yml)): green on `main` and on the `v1.0.0` tag.**
  - The Linux `swift:6.0` job builds and tests with warnings as errors: 64 tests pass.
  - The `macos-15` job runs 71 tests (64 core + 7 console-script) and the generic iOS Simulator build: `BUILD SUCCEEDED`.
- **What this does not verify:** no request in this repo reaches the real Messages API. Every number above and in the demo comes from `SimulatedThreadServer`, whose TTFT is *modelled* (`LatencyModel`), not measured, and whose keep-warm is a modelled two-message exchange. Before you tune `LatencyModel`, `TTLPolicy` or the break-even against real traffic, fit them from your relay's own telemetry.

## License

MIT
