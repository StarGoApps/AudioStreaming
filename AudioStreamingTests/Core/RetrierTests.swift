import XCTest
@testable import AudioStreaming

/// The reconnect backoff never grew, and the retry ran off the source's queue.
final class RetrierTests: XCTestCase {

    /// The remote source's retry callback is `seek`, which starts with `close` → `cancel()`.
    /// Doing the same here, the gaps between attempts must still grow: 1 s, 2 s, 4 s.
    func test_Backoff_Grows_Across_The_Cancel_That_Each_Retry_Makes() {
        let queue = DispatchQueue(label: "retrier.tests.backoff")
        let retrier = Retrier(interval: .seconds(1), maxInterval: 5, underlyingQueue: queue)
        let done = expectation(description: "three attempts")
        var firedAt: [Date] = []
        let start = Date()

        func attempt() {
            retrier.retry {
                firedAt.append(Date())
                retrier.cancel() // what `seek` → `close` does on every reconnect
                if firedAt.count == 3 {
                    done.fulfill()
                } else {
                    attempt() // the reconnect failed again
                }
            }
        }
        queue.async { attempt() }

        wait(for: [done], timeout: 12)
        let times = [start] + firedAt
        let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        XCTAssertEqual(gaps[0], 1, accuracy: 0.5, "gaps: \(gaps)")
        XCTAssertEqual(gaps[1], 2, accuracy: 0.5, "gaps: \(gaps)")
        XCTAssertEqual(gaps[2], 4, accuracy: 0.5, "gaps: \(gaps)")
    }

    func test_Delays_Double_Up_To_The_Cap() {
        let second = 1_000_000_000
        let expected: [DispatchTimeInterval] = [1, 2, 4, 5, 5, 5].map { .nanoseconds($0 * second) }
        var delays: [DispatchTimeInterval] = []
        for attempt in 0 ..< 6 {
            delays.append(Retrier.delay(forAttempt: attempt, base: .seconds(1), maxInterval: 5))
        }
        XCTAssertEqual(delays, expected)
    }

    func test_Reset_Starts_The_Backoff_Again() {
        let queue = DispatchQueue(label: "retrier.tests.reset")
        let retrier = Retrier(interval: .milliseconds(10), maxInterval: 5, underlyingQueue: queue)
        let fired = expectation(description: "fired")
        fired.expectedFulfillmentCount = 2
        queue.async {
            retrier.retry {
                fired.fulfill()
                retrier.retry { fired.fulfill() }
            }
        }
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(retrier.attempts, 2)

        retrier.reset()

        XCTAssertEqual(retrier.attempts, 0)
    }

    func test_A_Pending_Attempt_Is_Not_Scheduled_Twice() {
        let retrier = Retrier(interval: .milliseconds(200), maxInterval: 5, underlyingQueue: nil)
        let fired = expectation(description: "fired once")
        fired.assertForOverFulfill = true
        retrier.retry { fired.fulfill() }
        retrier.retry { fired.fulfill() }
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(retrier.attempts, 1)
    }

    /// The remote source builds its retrier itself; the retry has to run where `seek`'s other
    /// callers run, on the source's queue.
    func test_Remote_Source_Retries_On_Its_Own_Queue() {
        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "retrier.tests.source.queue")
        queue.setSpecific(key: key, value: "source")
        let source = RemoteAudioSource(networking: NetworkingClient(),
                                       url: URL(string: "http://127.0.0.1:9/never")!,
                                       underlyingQueue: queue)
        let fired = expectation(description: "retry callback")
        var ranOn: String?

        source.retrierTimeout.retry {
            ranOn = DispatchQueue.getSpecific(key: key)
            fired.fulfill()
        }

        wait(for: [fired], timeout: 3)
        XCTAssertEqual(ranOn, "source", "the retry ran off the source's queue")
        source.close()
    }
}
