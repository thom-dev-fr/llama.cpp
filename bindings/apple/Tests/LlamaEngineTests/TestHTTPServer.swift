import Foundation
import Network

/// A local HTTP/1.1 server whose behaviour the download tests control:
/// byte ranges with `If-Range`, entity tags, a connection cut after a given
/// number of body bytes, a bounded throughput, error statuses and content
/// replaced between requests. One request per connection.
final class TestHTTPServer: @unchecked Sendable {
    struct Resource {
        var data: Data
        /// Sent as `ETag` and checked against `If-Range`; nil sends neither
        /// `ETag` nor `Last-Modified`.
        var etag: String?
        var supportsRanges = true
        /// Answer this status instead of the content.
        var status: Int?
        /// Wait before answering.
        var delay: Duration?
    }

    struct Request: Hashable {
        var path: String
        var range: String?
        var ifRange: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http-server")
    private let lock = NSLock()
    // guarded by lock
    private var resources: [String: Resource] = [:]
    private var log: [Request] = []
    private var cuts: [String: Int] = [:]
    private var throttle: (chunk: Int, delay: Duration)?
    private var readyContinuation: CheckedContinuation<UInt16, any Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; returns the base URL.
    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { readyContinuation = continuation }
            listener.stateUpdateHandler = { [self] state in
                let continuation: CheckedContinuation<UInt16, any Error>? = lock.withLock {
                    switch state {
                    case .ready, .failed, .cancelled:
                        defer { readyContinuation = nil }
                        return readyContinuation
                    default:
                        return nil
                    }
                }
                switch state {
                case .ready: continuation?.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation?.resume(throwing: error)
                case .cancelled: continuation?.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        listener.cancel()
    }

    subscript(path: String) -> Resource? {
        get { lock.withLock { resources[path] } }
        set { lock.withLock { resources[path] = newValue } }
    }

    /// The next response for `path` closes the connection after `bytes` body bytes.
    func cut(_ path: String, after bytes: Int) {
        lock.withLock { cuts[path] = bytes }
    }

    /// Sends bodies in chunks of `chunk` bytes separated by `delay`; nil sends at once.
    func setThrottle(_ value: (chunk: Int, delay: Duration)?) {
        lock.withLock { throttle = value }
    }

    var requests: [Request] { lock.withLock { log } }

    func requests(for path: String) -> [Request] {
        requests.filter { $0.path == path }
    }

    // MARK: Connections

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [self] content, _, complete, error in
            var buffer = buffer
            if let content { buffer.append(content) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil && !complete {
                receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let path = parts.count > 1 ? String(parts[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let (resource, cut, throttle): (Resource?, Int?, (chunk: Int, delay: Duration)?) = lock.withLock {
            log.append(Request(path: path, range: headers["range"], ifRange: headers["if-range"]))
            return (resources[path], cuts.removeValue(forKey: path), self.throttle)
        }
        if let delay = resource?.delay {
            var copy = resource!
            copy.delay = nil
            let delayed = copy, headers = headers
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay.components.seconds * 1000 + delay.components.attoseconds / 1_000_000_000_000_000))) { [self] in
                answer(connection, resource: delayed, headers: headers, cut: cut, throttle: throttle)
            }
            return
        }
        answer(connection, resource: resource, headers: headers, cut: cut, throttle: throttle)
    }

    private func answer(_ connection: NWConnection, resource: Resource?, headers: [String: String], cut: Int?,
                        throttle: (chunk: Int, delay: Duration)?) {
        guard let resource, resource.status == nil else {
            let status = resource?.status ?? 404
            send(connection, head: "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                 body: Data(), cut: nil, throttle: nil)
            return
        }
        var start = 0
        var partial = false
        if resource.supportsRanges, let range = headers["range"],
           let match = range.wholeMatch(of: /bytes=(\d+)-/), let offset = Int(match.output.1), offset < resource.data.count,
           headers["if-range"].map({ $0 == resource.etag }) ?? true {
            start = offset
            partial = true
        }
        let body = resource.data.subdata(in: start..<resource.data.count)
        var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if partial {
            response += "Content-Range: bytes \(start)-\(resource.data.count - 1)/\(resource.data.count)\r\n"
        }
        if resource.supportsRanges {
            response += "Accept-Ranges: bytes\r\n"
        }
        if let etag = resource.etag {
            response += "ETag: \(etag)\r\nLast-Modified: Thu, 01 Oct 2026 00:00:00 GMT\r\n"
        }
        send(connection, head: response + "\r\n", body: body, cut: cut, throttle: throttle)
    }

    private func send(_ connection: NWConnection, head: String, body: Data, cut: Int?, throttle: (chunk: Int, delay: Duration)?) {
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let limit = min(body.count, cut ?? body.count)
        sendBody(connection, body, from: 0, limit: limit, isCut: cut != nil, throttle: throttle)
    }

    private func sendBody(_ connection: NWConnection, _ body: Data, from offset: Int, limit: Int, isCut: Bool,
                          throttle: (chunk: Int, delay: Duration)?) {
        guard offset < limit else {
            if isCut {
                connection.forceCancel() // abrupt: the client sees a short body
            } else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }
        let end = min(offset + (throttle?.chunk ?? limit), limit)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [self] error in
            guard error == nil else {
                connection.cancel()
                return
            }
            let next: @Sendable () -> Void = { self.sendBody(connection, body, from: end, limit: limit, isCut: isCut, throttle: throttle) }
            if let delay = throttle?.delay {
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay.components.seconds * 1000 +
                                                                       delay.components.attoseconds / 1_000_000_000_000_000)),
                                 execute: next)
            } else {
                next()
            }
        })
    }
}
