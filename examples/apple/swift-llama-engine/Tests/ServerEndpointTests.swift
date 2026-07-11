import Foundation
import FoundationModels
import Testing
@testable import LlamaServerLanguageModel

struct ServerEndpointTests {
    @Test func generationUsesChatCompletionsEndpoint() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.lastURL = nil

        var model = LlamaServerLanguageModel(
            name: "test-model",
            url: URL(string: "http://localhost:8080")!
        )
        model.urlSession = session
        let executor = LlamaServerLanguageModel.Executor(
            configuration: model.executorConfiguration
        )
        let request = LanguageModelExecutorGenerationRequest(
            id: UUID(),
            transcript: Transcript(entries: [
                .prompt(
                    Transcript.Prompt(
                        segments: [.text(Transcript.TextSegment(content: "Hello"))]
                    )
                )
            ]),
            enabledTools: [],
            generationOptions: GenerationOptions(),
            contextOptions: ContextOptions(),
            metadata: [:]
        )

        try await executor.respond(
            to: request,
            model: model,
            streamingInto: LanguageModelExecutorGenerationChannel()
        )

        #expect(MockURLProtocol.lastURL?.path == "/v1/chat/completions")
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let body = #"""
        data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}

        data: [DONE]

        """#.data(using: .utf8)!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
