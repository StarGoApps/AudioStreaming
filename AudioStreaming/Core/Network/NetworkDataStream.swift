//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

final class NetworkDataStream {
    typealias StreamResult = Result<Response, Error>
    typealias StreamCompletion = (_ event: NetworkDataStream.ResponseEvent) -> Void

    enum State {
        case initialised
        case resumed
        case suspended
        case cancelled
        case finished
    }

    struct Response {
        let response: HTTPURLResponse?
        let data: Data?
    }

    enum ResponseEvent {
        case stream(StreamResult)
        case complete(Completion)
        case response(HTTPURLResponse?)
    }

    struct Completion {
        let response: HTTPURLResponse?
        let error: Error?
    }

    /// `streamCallback`, `state` and `_task` are reached from the source's queue (`resume`,
    /// `cancel`), the networking client's queue (`didReceive…`) and the session's delegate queue,
    /// so every read and write of them goes through this lock (radio-tech-docs#2432).
    private let lock = UnfairLock()

    private var streamCallback: StreamCompletion?

    /// The serial queue for all internal async actions.
    private let underlyingQueue: DispatchQueue
    private let id: UUID

    private var state: State

    var isCancelled: Bool {
        lock.withLock { state == .cancelled }
    }

    private var _task: URLSessionTask?

    /// the underlying task of the network request
    var task: URLSessionTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    var urlResponse: HTTPURLResponse? {
        task?.response as? HTTPURLResponse
    }

    init(id: UUID, underlyingQueue: DispatchQueue) {
        self.id = id
        self.underlyingQueue = underlyingQueue
        state = .initialised
    }

    func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let task = session.dataTask(with: request)
        self.task = task
        return task
    }

    @discardableResult
    func responseStream(completion: @escaping StreamCompletion) -> Self {
        lock.withLock { streamCallback = completion }
        return self
    }

    @discardableResult
    func resume() -> Self {
        let task: URLSessionTask? = lock.withLock {
            guard state.canBecome(.resumed) else { return nil }
            state = .resumed
            return _task
        }
        task?.resume()
        return self
    }

    func cancel() {
        let task: URLSessionTask? = lock.withLock {
            guard state.canBecome(.cancelled) else { return nil }
            state = .cancelled
            streamCallback = nil
            defer { _task = nil }
            return _task
        }
        task?.cancel()
    }

    func suspend() {
        let task: URLSessionTask? = lock.withLock {
            guard state.canBecome(.suspended) else { return nil }
            state = .suspended
            return _task
        }
        task?.suspend()
    }

    /// The callback, read under the lock: `nil` once the stream was cancelled.
    private var currentCallback: StreamCompletion? {
        lock.withLock { streamCallback }
    }

    // MARK: Internal

    func didReceive(response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let streamCallback = self.currentCallback else { return }
            streamCallback(.response(response))
        }
    }

    func didReceive(data: Data, response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let streamCallback = self.currentCallback else { return }
            let streamResponse = Response(response: response, data: data)
            streamCallback(.stream(.success(streamResponse)))
        }
    }

    func didComplete(with error: Error?, response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let stream = self.currentCallback else { return }
            if let error = error {
                stream(.stream(.failure(error)))
            } else {
                let completion = Completion(response: response, error: error)
                stream(.complete(completion))
            }
        }
    }
}

// MARK: Equatable & Hashable

extension NetworkDataStream: Equatable {
    static func == (lhs: NetworkDataStream, rhs: NetworkDataStream) -> Bool {
        lhs.id == rhs.id
    }
}

extension NetworkDataStream: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension NetworkDataStream.State {
    func canBecome(_ state: NetworkDataStream.State) -> Bool {
        switch (self, state) {
        case (.initialised, _):
            return true
        case (_, .initialised),
             (.cancelled, _),
             (.finished, _):
            return false
        case (.resumed, .cancelled),
             (.resumed, .suspended),
             (.suspended, .resumed),
             (.suspended, .cancelled):
            return true
        case (.suspended, .suspended),
             (.resumed, .resumed):
            return false
        case (_, .finished):
            return true
        }
    }
}
