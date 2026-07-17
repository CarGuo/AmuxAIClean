import Foundation

/// Total conversion boundary for filesystem deadline inputs.
///
/// v2026.07.17 root-cause record: several scanners independently called
/// `Date.addingTimeInterval` with a public `Double`. NaN produced a deadline that never compared
/// true, turning a bounded scan into an unbounded one; enormous values also had undefined product
/// semantics across call sites. Keep the policy shared and explicit:
/// - NaN, negative values, -infinity and zero expire immediately;
/// - +infinity and finite values beyond Foundation's supported horizon saturate to distantFuture;
/// - ordinary positive finite values preserve their exact duration.
enum ScanDeadline {
    static func make(
        timeout: TimeInterval,
        now: Date = Date()
    ) -> Date {
        guard !timeout.isNaN, timeout > 0 else { return now }
        guard timeout.isFinite else { return .distantFuture }
        let remainingRepresentableInterval = Date.distantFuture.timeIntervalSince(now)
        guard timeout < remainingRepresentableInterval else { return .distantFuture }
        return now.addingTimeInterval(timeout)
    }
}
