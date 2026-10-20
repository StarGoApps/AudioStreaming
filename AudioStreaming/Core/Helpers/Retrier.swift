//
//  Created by Dimitrios Chatzieleftheriou on 13/11/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

/// An object that coordinates the retrying of a method (closure), backing off exponentially.
///
/// The delay before each attempt doubles from `interval` up to `maxInterval`: 1, 2, 4, 5, 5… s for
/// the remote source's 1 s / 5 s. It used to stay at 1 s for as long as a failure lasted, because
/// `cancel()` reset the interval and every attempt passed through it: `internalRetry()` called it
/// before scheduling, and the remote source's retry callback reaches it again through `seek` →
/// `close`. A long outage therefore reconnected about once a second.
///
/// `cancel()` now only stops a pending attempt. The attempt count survives it and goes back to
/// zero only through `reset()`, which the owner calls once the retried work has succeeded.
final class Retrier {
    private let lock = UnfairLock()
    private let baseDelay: DispatchTimeInterval
    private let maxInterval: Int
    private var _attempts = 0
    private var callback: (() -> Void)?

    private let timeoutTimer: DispatchTimerSource

    /// The queue the callback runs on. `nil` runs it on a global queue.
    let underlyingQueue: DispatchQueue?

    /// Initializes a new object with the given parameters
    /// - Parameters:
    ///   - interval: The delay before the first attempt; each later attempt waits twice as long.
    ///   - maxInterval: The longest delay, in seconds, between two attempts.
    ///   - underlyingQueue: An optional `DispatchQueue` objects to be assigned on the timer.
    init(interval: DispatchTimeInterval, maxInterval: Int, underlyingQueue: DispatchQueue?) {
        baseDelay = interval
        self.maxInterval = maxInterval
        self.underlyingQueue = underlyingQueue
        timeoutTimer = DispatchTimerSource(queue: underlyingQueue)
    }

    /// How many attempts have been scheduled since the last `reset()`.
    var attempts: Int {
        lock.withLock { _attempts }
    }

    /// Schedules the next attempt, unless one is already pending.
    ///
    /// The delay is `interval × 2^attempts`, capped at `maxInterval`.
    ///
    /// - Parameter callback: The method to be executed when timer is fired.
    func retry(callback: @escaping () -> Void) {
        lock.withLock {
            guard !timeoutTimer.isRunning else { return }
            self.callback = callback
            let delay = Retrier.delay(forAttempt: _attempts, base: baseDelay, maxInterval: maxInterval)
            _attempts += 1
            timeoutTimer.removeHandler()
            timeoutTimer.schedule(interval: delay, repeats: false)
            timeoutTimer.add { [weak self] in
                self?.fire()
            }
            timeoutTimer.activate()
        }
    }

    /// Cancels a pending attempt. The attempt count is kept, so the next `retry` backs off further.
    func cancel() {
        timeoutTimer.removeHandler()
        timeoutTimer.suspend()
    }

    /// The retried work succeeded: the next failure starts again from `interval`.
    func reset() {
        lock.withLock { _attempts = 0 }
    }

    /// The delay before attempt `attempt` (0-based): `base × 2^attempt`, capped at `maxInterval` s.
    static func delay(forAttempt attempt: Int, base: DispatchTimeInterval, maxInterval: Int) -> DispatchTimeInterval {
        let cap = max(Int64(maxInterval), 0) * 1_000_000_000
        var delay = max(base.nanoseconds, 1)
        for _ in 0 ..< max(attempt, 0) {
            guard delay < cap else { break }
            delay *= 2
        }
        return .nanoseconds(Int(min(delay, cap)))
    }

    // MARK: - Private

    private func fire() {
        // The one-shot timer stays activated after firing; suspend it so that the next `retry`
        // is not taken for a pending one, whether or not the callback cancels.
        timeoutTimer.suspend()
        let callback = lock.withLock { self.callback }
        callback?()
    }
}

private extension DispatchTimeInterval {
    var nanoseconds: Int64 {
        switch self {
        case let .seconds(value): return Int64(value) * 1_000_000_000
        case let .milliseconds(value): return Int64(value) * 1_000_000
        case let .microseconds(value): return Int64(value) * 1000
        case let .nanoseconds(value): return Int64(value)
        case .never: return Int64.max / 4
        @unknown default: return 1_000_000_000
        }
    }
}
