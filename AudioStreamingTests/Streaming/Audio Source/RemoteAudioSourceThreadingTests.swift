import Network
import XCTest
@testable import AudioStreaming

/// radio-tech-docs#2432 (macOS) / #2412 (iOS). The path monitor's callback ran on `net.path.queue`
/// and called `seek` → `close` there, off the source's queue; the header request's task stayed in
/// the networking client's task map for ever; and `NetworkDataStream` read and wrote its state
/// from three queues with no lock. On iOS the race shows as SIGSEGV/SIGTRAP in
/// `NetworkDataStream.__deallocating_deinit` and `NetworkingClient.remove(task:)`.
///
/// Run under Thread Sanitizer: `swift test --sanitize=thread --filter RemoteAudioSourceThreadingTests`.
final class RemoteAudioSourceThreadingTests: XCTestCase {
    private var server: LoopbackStreamServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try LoopbackStreamServer()
        try server.start()
        XCTAssertGreaterThan(server.port, 0, "server failed to bind a port")
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    private func makeSource(networking: NetworkingClient, net: NetStatusProvider, queue: DispatchQueue) throws -> RemoteAudioSource {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/live.mp3"))
        return RemoteAudioSource(networking: networking,
                                 metadataStreamSource: MetadataStreamProcessor(parser: MetadataParser().eraseToAnyParser()),
                                 icycastHeadersProcessor: IcycastHeadersProcessor(),
                                 netStatusProvider: net,
                                 retrier: Retrier(interval: .seconds(1), maxInterval: 5, underlyingQueue: queue),
                                 url: url,
                                 httpMethod: nil,
                                 httpBody: nil,
                                 underlyingQueue: queue,
                                 httpHeaders: [:])
    }

    /// The header request that starts every open is taken out of the networking client's task
    /// map once it has answered: after `close`, the map is empty. Red before the fix: the header
    /// request stayed in it.
    func test_Close_Leaves_No_Task_In_The_Networking_Client() throws {
        let queue = DispatchQueue(label: "remote.audio.source.threading.tests.tasks")
        let networking = NetworkingClient()
        let received = expectation(description: "audio arrived")
        received.assertForOverFulfill = false
        let delegate = DataSpy { received.fulfill() }
        let source = try makeSource(networking: networking, net: ManualNetStatusProvider(), queue: queue)
        source.delegate = delegate

        queue.sync { source.seek(at: 0) }
        wait(for: [received], timeout: 10)
        queue.sync { source.close() }

        let empty = networking.tasksLock.withLock { networking.tasks.isEmpty }
        XCTAssertTrue(empty, "a task stayed in the networking client's map after close")
    }

    /// The path monitor reports «connected» from its own queue while the player seeks on the
    /// source's queue. The callback must land on the source's queue, so the two never touch
    /// `streamRequest` and the task map at once. Under Thread Sanitizer, red before the fix
    /// (a data race on `RemoteAudioSource.streamRequest` / `waitingForNetwork`).
    func test_A_Path_Change_While_Seeking_Stays_On_The_Source_Queue() throws {
        let queue = DispatchQueue(label: "remote.audio.source.threading.tests.path")
        let net = ManualNetStatusProvider()
        let source = try makeSource(networking: NetworkingClient(), net: net, queue: queue)
        source.delegate = DataSpy {}
        let pathQueue = DispatchQueue(label: "test.net.path.queue")
        let rounds = 50
        let done = expectation(description: "path changes delivered")
        done.expectedFulfillmentCount = rounds

        for _ in 0 ..< rounds {
            queue.async {
                source.waitingForNetwork = true
                source.seek(at: 0)
            }
            pathQueue.async {
                net.fire(.wifi(connected: true))
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        // Let the hops land, then close on the source's queue.
        queue.sync {}
        queue.sync { source.close() }
        XCTAssertTrue(net.observed, "the source listens to the path monitor")
    }
}

// MARK: - Helpers

private final class ManualNetStatusProvider: NetStatusProvider {
    private var callback: ((NetConnectionType) -> Void)?
    private(set) var observed = false
    var isConnected: Bool { true }
    var connectionType: NetConnectionType { .wifi(connected: true) }
    func start(connectionChange: @escaping (NetConnectionType) -> Void) {
        callback = connectionChange
        observed = true
    }

    func stop() {}
    func fire(_ type: NetConnectionType) { callback?(type) }
}

private final class DataSpy: AudioStreamSourceDelegate {
    private let onData: () -> Void
    init(onData: @escaping () -> Void) { self.onData = onData }
    func dataAvailable(source _: CoreAudioStreamSource, data _: Data) { onData() }
    func errorOccurred(source _: CoreAudioStreamSource, error _: Error) {}
    func endOfFileOccurred(source _: CoreAudioStreamSource) {}
    func metadataReceived(data _: [String: String]) {}
}

/// A loopback HTTP server that answers every request with a 200 `audio/mpeg` body of no known
/// length, a few kilobytes at a time, until the client goes away.
private final class LoopbackStreamServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback.stream.server")
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, _ in
            let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            self?.pump(connection, remaining: 200)
        }
    }

    private func pump(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        connection.send(content: Data(repeating: 0xFF, count: 4096), completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            self?.queue.asyncAfter(deadline: .now() + 0.02) { self?.pump(connection, remaining: remaining - 1) }
        })
    }
}
