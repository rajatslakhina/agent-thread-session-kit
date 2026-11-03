import Foundation

/// A simple linear model of time-to-first-token: a fixed floor plus a per-uploaded-token cost.
/// The point is the *shape* — TTFT grows with what you upload — not the absolute numbers, which
/// a team should fit from its own telemetry (`TurnRecord.ttftMs`).
public struct LatencyModel: Sendable, Equatable {
    public let baseMs: Double
    public let msPerUploadedKToken: Double

    public init(baseMs: Double = 600, msPerUploadedKToken: Double = 9) {
        self.baseMs = (baseMs.isFinite && baseMs >= 0) ? baseMs : 0
        self.msPerUploadedKToken = (msPerUploadedKToken.isFinite && msPerUploadedKToken >= 0) ? msPerUploadedKToken : 0
    }

    public func ttftMs(uploadedTokens: Int) -> Double {
        baseMs + Double(max(uploadedTokens, 0)) / 1000 * msPerUploadedKToken
    }
}

/// Environment the keep-warm decision depends on. Fed by `LifecycleEvent`s.
public struct DeviceConditions: Sendable, Equatable {
    public var isForeground: Bool
    public var isLowPowerMode: Bool
    public var isExpensiveNetwork: Bool

    public init(isForeground: Bool = true, isLowPowerMode: Bool = false, isExpensiveNetwork: Bool = false) {
        self.isForeground = isForeground
        self.isLowPowerMode = isLowPowerMode
        self.isExpensiveNetwork = isExpensiveNetwork
    }
}

public enum KeepWarmDecision: Sendable, Equatable {
    case ping
    case skip(KeepWarmSkipReason)
}

public enum KeepWarmSkipReason: String, Sendable, Equatable {
    case disabled, noThread, notExpiringYet, alreadyExpired, backgrounded, lowPowerMode, expensiveNetwork
    case consecutiveLimit, notWorthIt, turnInFlight
    /// Local messages the server has not seen yet (e.g. closing tool results). A ping would put
    /// its exchange *before* them on the server and *after* them locally.
    case pendingLocalMessages
    /// `reset()` ran while the ping was in flight; its result was discarded.
    case cancelledByReset
    /// The synced prefix was rewritten locally (edit/redaction); only a full resend can fix it.
    case prefixDiverged
}

/// Decides whether keeping a thread alive is worth paying for.
///
/// The non-obvious input: **a keep-warm is not free**. Message threads cut what you *upload*,
/// not what Claude *reads* — every request still reads the full conversation, so a ping bills
/// roughly the whole context in input tokens. The policy therefore compares
///
///     P(user returns before expiry) × latency saved × value of a second
///
/// against `contextTokens × pricePerInputToken`, and is gated by device conditions and a hard
/// cap on consecutive pings so an idle, foregrounded app cannot spend forever.
public struct KeepWarmPolicy: Sendable, Equatable {
    /// Probability the user sends another turn within the next TTL window, in `[0, 1]`.
    public let returnProbability: Double
    /// What one second of saved latency is worth, in dollars. Product-owned, not engineering-owned.
    public let dollarsPerSecondSaved: Double
    /// Input price, in dollars per million tokens (cache reads, if the relay uses prompt caching).
    public let dollarsPerMillionInputTokens: Double
    public let maxConsecutivePings: Int
    public let latency: LatencyModel

    public init(
        returnProbability: Double = 0.35,
        dollarsPerSecondSaved: Double = 0.002,
        dollarsPerMillionInputTokens: Double = 0.30,
        maxConsecutivePings: Int = 2,
        latency: LatencyModel = LatencyModel()
    ) {
        self.returnProbability = returnProbability.isFinite ? min(max(returnProbability, 0), 1) : 0
        self.dollarsPerSecondSaved = (dollarsPerSecondSaved.isFinite && dollarsPerSecondSaved > 0) ? dollarsPerSecondSaved : 0
        self.dollarsPerMillionInputTokens = (dollarsPerMillionInputTokens.isFinite && dollarsPerMillionInputTokens > 0) ? dollarsPerMillionInputTokens : 0
        self.maxConsecutivePings = max(0, maxConsecutivePings)
        self.latency = latency
    }

    /// Never ping. The safe default for apps that have not measured anything yet.
    public static let disabled = KeepWarmPolicy(returnProbability: 0, maxConsecutivePings: 0)

    /// The value of a saved second above which a ping pays for itself, for large contexts.
    ///
    /// Both sides of the comparison are linear in context size (cost: tokens × price; benefit:
    /// tokens × upload latency × p × value), so the context size cancels out and break-even depends
    /// only on price, upload latency and return probability. `.infinity` when a ping can never pay.
    public var breakEvenDollarsPerSecond: Double {
        let denominator = returnProbability * latency.msPerUploadedKToken
        guard denominator > 0 else { return .infinity }
        return dollarsPerMillionInputTokens / denominator
    }

    /// Dollars expected to be saved by keeping the thread alive.
    public func expectedBenefit(contextTokens: Int, typicalDeltaTokens: Int) -> Double {
        let full = latency.ttftMs(uploadedTokens: contextTokens)
        let delta = latency.ttftMs(uploadedTokens: typicalDeltaTokens)
        let savedSeconds = max(full - delta, 0) / 1000
        return returnProbability * savedSeconds * dollarsPerSecondSaved
    }

    /// Dollars a single keep-warm request costs.
    public func pingCost(contextTokens: Int) -> Double {
        Double(max(contextTokens, 0)) / 1_000_000 * dollarsPerMillionInputTokens
    }

    public func decide(
        liveness: TTLPolicy.Liveness?,
        conditions: DeviceConditions,
        consecutivePings: Int,
        contextTokens: Int,
        typicalDeltaTokens: Int
    ) -> KeepWarmDecision {
        guard maxConsecutivePings > 0, returnProbability > 0 else { return .skip(.disabled) }
        guard let liveness else { return .skip(.noThread) }
        switch liveness {
        case .live: return .skip(.notExpiringYet)
        case .expired: return .skip(.alreadyExpired)
        case .expiring: break
        }
        // Device gates come before economics: a background ping cannot be scheduled reliably on
        // iOS anyway, and Low Power Mode is the user telling us to stop spending energy.
        guard conditions.isForeground else { return .skip(.backgrounded) }
        guard !conditions.isLowPowerMode else { return .skip(.lowPowerMode) }
        guard !conditions.isExpensiveNetwork else { return .skip(.expensiveNetwork) }
        guard consecutivePings < maxConsecutivePings else { return .skip(.consecutiveLimit) }
        let benefit = expectedBenefit(contextTokens: contextTokens, typicalDeltaTokens: typicalDeltaTokens)
        let cost = pingCost(contextTokens: contextTokens)
        return benefit > cost ? .ping : .skip(.notWorthIt)
    }
}
