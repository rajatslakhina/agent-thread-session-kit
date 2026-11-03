import Foundation

// MARK: - Saturating arithmetic

/// Addition that clamps instead of trapping. Every counter in this module that is fed by
/// caller-supplied sizes (token counts, request counts) goes through it, so no public input can
/// reach a Swift overflow trap.
enum Saturating {
    static func add(_ a: Int, _ b: Int) -> Int {
        let (r, overflow) = a.addingReportingOverflow(b)
        if overflow { return b > 0 ? Int.max : Int.min }
        return r
    }

}

// MARK: - Stable digest

/// A 64-bit FNV-1a digest that is stable across processes, launches and platforms.
///
/// `Hasher` is randomly seeded per process, so a transcript digest computed with it would differ
/// after every relaunch and silently break prefix checks on a rehydrated session. FNV-1a is used
/// for *identity and divergence detection*, not for security: a malicious peer could forge a
/// collision. The trust boundary (who may write the transcript) is the app itself.
public struct StableDigest: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let seed = StableDigest(rawValue: 0xcbf2_9ce4_8422_2325)
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    public var description: String {
        let hex = String(rawValue, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Returns a new digest with `bytes` folded in.
    public func folding<S: Sequence>(_ bytes: S) -> StableDigest where S.Element == UInt8 {
        var h = rawValue
        for b in bytes {
            h ^= UInt64(b)
            h = h &* Self.prime   // wrapping multiply is the FNV definition, not an overflow bug
        }
        return StableDigest(rawValue: h)
    }

    /// Folds a length-prefixed string, so ("ab","c") and ("a","bc") never collide by construction.
    public func folding(field: String) -> StableDigest {
        let utf8 = Array(field.utf8)
        return folding(UInt64(utf8.count).littleEndianBytes).folding(utf8)
    }

    public func folding(tag: UInt8) -> StableDigest { folding(CollectionOfOne(tag)) }

    public func folding(digest: StableDigest) -> StableDigest { folding(digest.rawValue.littleEndianBytes) }
}

extension UInt64 {
    var littleEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: self >> (UInt64($0) * 8)) }
    }
}

// MARK: - Clock

/// Seconds on a clock that **keeps counting while the device sleeps**.
///
/// The server's thread TTL is wall time. A clock that pauses during sleep (`SuspendingClock`,
/// `mach_absolute_time`, `DispatchTime`) under-reports elapsed time after the phone has been
/// locked, and the session would send a delta to a thread that died minutes ago.
public protocol SessionClock: Sendable {
    func now() -> TimeInterval
}

/// Production clock: `ContinuousClock` advances across system sleep.
public struct ContinuousSessionClock: SessionClock {
    private let origin: ContinuousClock.Instant
    public init() { origin = ContinuousClock.now }
    public func now() -> TimeInterval {
        let d = ContinuousClock.now - origin
        let (seconds, attoseconds) = d.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// A clock the caller advances by hand. Used by the tests and by the demo's time-travel controls.
///
/// `@unchecked Sendable` is justified: the only stored state is guarded by `lock`.
public final class ManualClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    public init(start: TimeInterval = 0) { current = start.isFinite ? start : 0 }

    public func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Advances time. Non-finite or negative amounts are ignored: this clock is monotonic.
    public func advance(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let next = current + seconds
        current = next.isFinite ? next : current   // a huge finite sum must not reach +inf
    }
}
