import Network
import XCTest
@testable import AudioStreaming

/// A live stream's server that closes the connection cleanly — a restart, a mount switch — has not
/// reached an end of file: a response with no known length has none. The source has to reconnect
/// through the `Retrier`, as it does for a dropped connection. A file of known length still ends.
final class RemoteAudioSourceCleanCloseTests: XCTestCase {
    private var server: ClosingStreamServer!
    private var source: RemoteAudioSource!
    private var delegate: CleanCloseDelegateSpy!

    override func tearDownWithError() throws {
        source?.close()
        source = nil
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    /// Icecast's shape: `HTTP/1.x 200`, no `Content-Length`, the body ends when the socket closes.
    func test_Live_Stream_Closed_Cleanly_Reconnects_Instead_Of_Ending() throws {
        try assertReconnects(after: .closeDelimited(bodyBytes: 4096))
    }

    /// The same with a chunked body that ends with its last chunk.
    func test_Chunked_Live_Stream_Closed_Cleanly_Reconnects_Instead_Of_Ending() throws {
        try assertReconnects(after: .chunked(bodyBytes: 4096))
    }

    /// A server that answers and closes at once, every time, delivers no audio: the reconnects back
    /// off 1, 2, 4 s like any failing reconnect, rather than hammer it once a second.
    func test_A_Server_That_Keeps_Closing_At_Once_Is_Retried_With_Backoff() throws {
        server = try ClosingStreamServer(mode: .closeDelimited(bodyBytes: 0))
        try server.start()
        let fourth = expectation(description: "the fourth stream connection")
        server.onStreamConnection = { count in
            if count == 4 { fourth.fulfill() }
        }
        delegate = CleanCloseDelegateSpy()
        try startSource()

        wait(for: [fourth], timeout: 15)
        let gaps = server.streamConnectionGaps()
        XCTAssertEqual(gaps.count, 3, "gaps: \(gaps)")
        guard gaps.count == 3 else { return }
        XCTAssertEqual(gaps[0], 1, accuracy: 0.6, "gaps: \(gaps)")
        XCTAssertEqual(gaps[1], 2, accuracy: 0.6, "gaps: \(gaps) — the backoff did not grow")
        XCTAssertEqual(gaps[2], 4, accuracy: 0.6, "gaps: \(gaps) — the backoff did not grow")
        XCTAssertEqual(delegate.endOfFileCount, 0, "a clean close of a live stream was reported as the end of the file")
    }

    /// Each reconnect delivers audio and is closed again: audio resets the attempt count, so every
    /// reconnect comes after the first delay, 1 s, not 2, 4, 5 s.
    func test_Backoff_Starts_Over_When_Audio_Arrives_Again() throws {
        server = try ClosingStreamServer(mode: .closeDelimited(bodyBytes: 4096))
        try server.start()
        let fourth = expectation(description: "the fourth stream connection")
        server.onStreamConnection = { count in
            if count == 4 { fourth.fulfill() }
        }
        delegate = CleanCloseDelegateSpy()
        try startSource()

        wait(for: [fourth], timeout: 10)
        let gaps = server.streamConnectionGaps()
        XCTAssertEqual(gaps.count, 3, "gaps: \(gaps)")
        for gap in gaps {
            XCTAssertEqual(gap, 1, accuracy: 0.6, "gaps: \(gaps) — audio did not reset the backoff")
        }
    }

    /// A file served with its `Content-Length` that is read to the end is the end of the file: no
    /// reconnect.
    func test_File_Of_Known_Length_Still_Ends() throws {
        server = try ClosingStreamServer(mode: .contentLength(bodyBytes: 4096))
        try server.start()
        let ended = expectation(description: "end of file")
        delegate = CleanCloseDelegateSpy(onEndOfFile: { ended.fulfill() })
        try startSource()

        wait(for: [ended], timeout: 5)
        // Longer than the first retry delay (1 s): a reconnect would have opened a second stream.
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(server.streamConnectionCount, 1, "a file that ended was reconnected")
        XCTAssertEqual(delegate.endOfFileCount, 1)
    }

    // MARK: - Helpers

    private func assertReconnects(after mode: ClosingStreamServer.Mode,
                                  file: StaticString = #filePath, line: UInt = #line) throws
    {
        server = try ClosingStreamServer(mode: mode)
        try server.start()
        let resumed = expectation(description: "audio from the stream after the clean close")
        resumed.assertForOverFulfill = false
        delegate = CleanCloseDelegateSpy(onData: { data in
            if data.contains(2) { resumed.fulfill() }
        })
        try startSource()

        wait(for: [resumed], timeout: 5)
        XCTAssertEqual(delegate.endOfFileCount, 0,
                       "a clean close of a live stream was reported as the end of the file",
                       file: file, line: line)
    }

    private func startSource() throws {
        XCTAssertGreaterThan(server.port, 0, "server failed to bind a port")
        let queue = DispatchQueue(label: "remote.audio.source.clean.close.tests")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/live.mp3"))
        source = RemoteAudioSource(networking: NetworkingClient(),
                                   metadataStreamSource: MetadataStreamProcessor(parser: MetadataParser().eraseToAnyParser()),
                                   icycastHeadersProcessor: IcycastHeadersProcessor(),
                                   netStatusProvider: AlwaysConnectedNetStatusProvider(),
                                   retrier: Retrier(interval: .seconds(1), maxInterval: 5, underlyingQueue: queue),
                                   url: url,
                                   httpMethod: nil,
                                   httpBody: nil,
                                   underlyingQueue: queue,
                                   httpHeaders: [:])
        source.delegate = delegate
        queue.sync { source.seek(at: 0) }
    }
}

private final class AlwaysConnectedNetStatusProvider: NetStatusProvider {
    var isConnected: Bool { true }
    var connectionType: NetConnectionType { .wifi(connected: true) }
    func start(connectionChange _: @escaping (NetConnectionType) -> Void) {}
    func stop() {}
}

private final class CleanCloseDelegateSpy: AudioStreamSourceDelegate {
    private let lock = NSLock()
    private let onData: (Data) -> Void
    private let onEndOfFile: () -> Void
    private var _endOfFileCount = 0
    var endOfFileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _endOfFileCount
    }

    init(onData: @escaping (Data) -> Void = { _ in }, onEndOfFile: @escaping () -> Void = {}) {
        self.onData = onData
        self.onEndOfFile = onEndOfFile
    }

    func dataAvailable(source _: CoreAudioStreamSource, data: Data) { onData(data) }
    func errorOccurred(source _: CoreAudioStreamSource, error _: Error) {}
    func endOfFileOccurred(source _: CoreAudioStreamSource) {
        lock.lock()
        _endOfFileCount += 1
        lock.unlock()
        onEndOfFile()
    }

    func metadataReceived(data _: [String: String]) {}
}

/// A loopback HTTP server whose every stream response ends in a clean close (FIN, no error).
/// The body of the n-th stream connection is filled with the byte `n`, so a client can tell a
/// reconnect's audio from the first connection's. The source's range probe (`Range: bytes=0-1`) is
/// answered like a real server of that kind — a live server ignores the range, a file server gives
/// a 206 with the total — and is not counted as a stream connection.
private final class ClosingStreamServer {
    enum Mode {
        /// `200`, no `Content-Length`; the body ends when the server closes the socket.
        case closeDelimited(bodyBytes: Int)
        /// `200`, `Transfer-Encoding: chunked`; one chunk, the last chunk, then a close.
        case chunked(bodyBytes: Int)
        /// `200` with a `Content-Length` and exactly that many bytes: a file.
        case contentLength(bodyBytes: Int)
    }

    var onStreamConnection: ((Int) -> Void)?

    private let mode: Mode
    private let listener: NWListener
    private let queue = DispatchQueue(label: "closing.stream.server")
    private var connections: [NWConnection] = []
    private var streamConnectedAt: [Date] = []
    private(set) var port: UInt16 = 0

    var streamConnectionCount: Int { queue.sync { streamConnectedAt.count } }

    /// Seconds between consecutive stream connections.
    func streamConnectionGaps() -> [TimeInterval] {
        queue.sync {
            zip(streamConnectedAt.dropFirst(), streamConnectedAt).map { $0.timeIntervalSince($1) }
        }
    }

    init(mode: Mode) throws {
        self.mode = mode
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, _, _ in
            guard let self, let connection else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let isRangeProbe = request.range(of: "\r\nRange:", options: .caseInsensitive) != nil
        if isRangeProbe {
            send(probeResponse(), on: connection)
            return
        }
        streamConnectedAt.append(Date())
        let count = streamConnectedAt.count
        onStreamConnection?(count)
        let fill = UInt8(truncatingIfNeeded: count)

        var response: Data
        switch mode {
        case let .closeDelimited(bodyBytes):
            response = Data(("HTTP/1.1 200 OK\r\n"
                    + "Content-Type: audio/mpeg\r\n"
                    + "Connection: close\r\n\r\n").utf8)
            response.append(Data(repeating: fill, count: bodyBytes))
        case let .chunked(bodyBytes):
            response = Data(("HTTP/1.1 200 OK\r\n"
                    + "Content-Type: audio/mpeg\r\n"
                    + "Transfer-Encoding: chunked\r\n"
                    + "Connection: close\r\n\r\n"
                    + String(bodyBytes, radix: 16) + "\r\n").utf8)
            response.append(Data(repeating: fill, count: bodyBytes))
            response.append(Data("\r\n0\r\n\r\n".utf8))
        case let .contentLength(bodyBytes):
            response = Data(("HTTP/1.1 200 OK\r\n"
                    + "Content-Type: audio/mpeg\r\n"
                    + "Content-Length: \(bodyBytes)\r\n"
                    + "Connection: close\r\n\r\n").utf8)
            response.append(Data(repeating: fill, count: bodyBytes))
        }
        send(response, on: connection)
    }

    private func probeResponse() -> Data {
        switch mode {
        case .closeDelimited, .chunked:
            // A live server ignores the range and starts the stream; the source cancels the probe
            // once it has the headers.
            return Data(("HTTP/1.1 200 OK\r\n"
                    + "Content-Type: audio/mpeg\r\n"
                    + "Connection: close\r\n\r\n").utf8)
        case let .contentLength(bodyBytes):
            var data = Data(("HTTP/1.1 206 Partial Content\r\n"
                    + "Content-Type: audio/mpeg\r\n"
                    + "Accept-Ranges: bytes\r\n"
                    + "Content-Range: bytes 0-1/\(bodyBytes)\r\n"
                    + "Content-Length: 2\r\n"
                    + "Connection: close\r\n\r\n").utf8)
            data.append(Data([0, 0]))
            return data
        }
    }

    /// Sends the whole response and closes the socket cleanly (FIN) once it is out.
    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak connection] _ in
                            connection?.cancel()
                        })
    }
}
