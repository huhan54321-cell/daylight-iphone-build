import Foundation

// Bound the whole request, read chunks off the main actor, and cancel the socket on view cancellation.
final class CareerAssistantTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var cancelled = false
    private var deadline: DispatchWorkItem?
    static func perform(_ request: URLRequest, timeout: TimeInterval = 12, protocols: [AnyClass]? = nil) async throws -> (Data, HTTPURLResponse) {
        let reader = CareerAssistantTransport()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reader.start(request, timeout: timeout, protocols: protocols, continuation: $0) }
        } onCancel: { reader.cancel() }
    }
    private func start(_ request: URLRequest, timeout: TimeInterval, protocols: [AnyClass]?, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = min(8, timeout); config.timeoutIntervalForResource = timeout
        if let protocols { config.protocolClasses = protocols }
        config.waitsForConnectivity = false; config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session; task = session.dataTask(with: request)
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(CareerServiceError.timeout)) }; self.deadline = deadline
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        task?.resume(); lock.unlock()
    }
    private func cancel() { lock.lock(); cancelled = true; lock.unlock(); finish(.failure(CancellationError())) }
    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock(); let callback = continuation; continuation = nil; let current = session; session = nil; task = nil; deadline?.cancel(); deadline = nil; lock.unlock()
        current?.invalidateAndCancel(); callback?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= 16_777_216 else { completionHandler(.cancel); finish(.failure(CareerFeedError.tooLarge)); return }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 16_777_216 else { finish(.failure(CareerFeedError.tooLarge)); return }; bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((bytes, response))) }
        else { finish(.failure(CareerServiceError.transport)) }
    }
}
