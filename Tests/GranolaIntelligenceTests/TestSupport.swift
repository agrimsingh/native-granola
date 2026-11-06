import Foundation
@testable import GranolaIntelligence

struct MockReply {
    var status: Int = 200
    var body: Data = Data()
    var headers: [String: String] = [:]
    /// For streaming: body delivered in these chunks (defaults to `body` as one chunk).
    var chunks: [Data]?

    static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> MockReply {
        MockReply(status: status, body: try! value.encoded(), headers: headers)
    }

    static func text(_ string: String, status: Int = 200) -> MockReply {
        MockReply(status: status, body: Data(string.utf8))
    }
}

final class MockHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) throws -> MockReply

    /// `handler` gets the request and its zero-based index.
    init(_ handler: @escaping @Sendable (URLRequest, Int) throws -> MockReply) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    private func record(_ request: URLRequest) throws -> (MockReply, HTTPURLResponse) {
        let index: Int = lock.withLock {
            _requests.append(request)
            return _requests.count - 1
        }
        let reply = try handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply, response)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (reply, response) = try record(request)
        return (reply.body, response)
    }

    func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (reply, response) = try record(request)
        let chunks = reply.chunks ?? [reply.body]
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return (response, stream)
    }
}

func bodyJSON(_ request: URLRequest) throws -> JSONValue {
    try JSONValue.decode(request.httpBody ?? Data())
}

func sseChunks(_ text: String, size: Int) -> [Data] {
    let bytes = Array(text.utf8)
    return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
}
