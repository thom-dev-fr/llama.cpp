public import Foundation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif

@available(iOS 27.0, macOS 27.0, *)
public struct LlamaOpenAICompatibleStreamingClient: Sendable {
    public let baseURL: URL
    public let headers: [String: String]
    public let session: URLSession

    public init(baseURL: URL, headers: [String: String], session: URLSession) {
        self.baseURL = baseURL
        self.headers = headers
        self.session = session
    }

    public func stream<Request: Encodable, Chunk: Decodable & Sendable>(
        endpoint: String,
        request: Request,
        invalidStreamData: @escaping @Sendable () -> any Error,
        httpError: @escaping @Sendable (_ statusCode: Int, _ data: Data) -> any Error,
        apiError: @escaping @Sendable (_ error: LlamaOpenAICompatibleErrorResponse.APIError) -> any Error
    ) -> AsyncThrowingStream<Chunk, any Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try buildURLRequest(endpoint: endpoint, body: request)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(Darwin)
                    let (stream, response) = try await session.bytes(for: urlRequest)
                    let httpResponse = response as! HTTPURLResponse

                    guard httpResponse.statusCode == 200 else {
                        throw httpError(
                            httpResponse.statusCode,
                            try await stream.reduce(Data(), { $0 + [$1] })
                        )
                    }

                    for try await line in stream.lines {
                        if let chunk: Chunk = try LlamaOpenAICompatibleSSE.parseStreamLine(
                            line,
                            invalidStreamData: invalidStreamData,
                            apiError: apiError
                        ) {
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()
                    #else
                    let (data, response) = try await session.data(for: urlRequest)
                    let httpResponse = response as! HTTPURLResponse

                    guard httpResponse.statusCode == 200 else {
                        throw httpError(httpResponse.statusCode, data)
                    }

                    let body = String(data: data, encoding: .utf8) ?? ""
                    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                        if let chunk: Chunk = try LlamaOpenAICompatibleSSE.parseStreamLine(
                            String(line),
                            invalidStreamData: invalidStreamData,
                            apiError: apiError
                        ) {
                            continuation.yield(chunk)
                        }
                    }

                    continuation.finish()
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildURLRequest<Request: Encodable>(
        endpoint: String,
        body: Request
    ) throws -> URLRequest {
        let isVersioned = baseURL.pathComponents.contains("v1")
        let endpoint = isVersioned ? endpoint : "/v1" + endpoint
        let url = baseURL.appendingPathComponent(endpoint)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        for (header, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: header)
        }
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }
}

@available(iOS 27.0, macOS 27.0, *)
enum LlamaOpenAICompatibleSSE {
    static func parseStreamLine<Chunk: Decodable & Sendable>(
        _ line: String,
        invalidStreamData: () -> any Error,
        apiError: (_ error: LlamaOpenAICompatibleErrorResponse.APIError) -> any Error
    ) throws -> Chunk? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix(":"), trimmedLine.hasPrefix("data: ") else {
            return nil
        }

        let jsonString = String(trimmedLine.dropFirst(6))
        if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return nil
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw invalidStreamData()
        }

        let decoder = JSONDecoder()
        if let response = try? decoder.decode(LlamaOpenAICompatibleErrorResponse.self, from: jsonData) {
            throw apiError(response.error)
        }

        do {
            return try decoder.decode(Chunk.self, from: jsonData)
        } catch {
            throw invalidStreamData()
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
public struct LlamaOpenAICompatibleErrorResponse: Codable, Sendable {
    public var error: APIError

    public struct APIError: Codable, Sendable {
        public var message: String
        public var type: String?
        public var param: String?
        public var code: String?

        public init(message: String, type: String? = nil, param: String? = nil, code: String? = nil) {
            self.message = message
            self.type = type
            self.param = param
            self.code = code
        }
    }

    public init(error: APIError) {
        self.error = error
    }
}

@available(iOS 27.0, macOS 27.0, *)
public struct LlamaOpenAICompatibleEndpointConfiguration: Hashable, Sendable {
    public let modelName: String
    public let baseURL: URL
    public let headers: [String: String]

    public init(
        modelName: String,
        baseURL: URL,
        additionalHeaders: [String: String]
    ) {
        self.modelName = modelName
        self.baseURL = baseURL
        self.headers = LlamaOpenAICompatibleDefaults.headers(additionalHeaders: additionalHeaders)
    }

    public func streamingClient(session: URLSession?) -> LlamaOpenAICompatibleStreamingClient {
        LlamaOpenAICompatibleStreamingClient(
            baseURL: baseURL,
            headers: headers,
            session: LlamaOpenAICompatibleDefaults.session(overriding: session)
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
enum LlamaOpenAICompatibleDefaults {
    static func headers(additionalHeaders: [String: String]) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "User-Agent": Bundle.main.bundleIdentifier ?? "org.llama.cpp.swift-llama-engine"
        ].merging(additionalHeaders, uniquingKeysWith: { _, custom in custom })
    }

    static func session(overriding session: URLSession?) -> URLSession {
        session ?? URLSession(configuration: .ephemeral)
    }
}
