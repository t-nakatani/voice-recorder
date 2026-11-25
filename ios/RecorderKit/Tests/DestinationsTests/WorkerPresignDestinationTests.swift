import Foundation
import RecorderCore
import Testing
@testable import Destinations

final class RecordingHTTP: HTTPClient, @unchecked Sendable {
    var requests: [URLRequest] = []
    var response: (Data, Int)
    init(response: (Data, Int)) { self.response = response }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return response
    }
}

@Suite struct WorkerPresignDestinationTests {
    let descriptor = UploadDescriptor(key: "recordings/r/segments/000000.m4a", contentType: "audio/mp4",
                                      byteCount: 1234, sha256Hex: "ab")

    @Test func sendsTokenAndDescriptorAndParsesResponse() async throws {
        let body = #"{"url":"https://acc.r2.cloudflarestorage.com/b/k?X-Amz-Signature=x","method":"PUT","headers":{"Content-Type":"audio/mp4"},"expiresAt":"2026-11-25T10:00:00Z"}"#
        let http = RecordingHTTP(response: (Data(body.utf8), 200))
        let destination = WorkerPresignDestination(id: "r2", endpoint: URL(string: "https://ingest.example.dev")!,
                                                   http: http) { "secret-token" }
        let prepared = try await destination.prepareUpload(descriptor)

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://ingest.example.dev/v1/presign")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        let sent = try JSONDecoder().decode(WorkerPresignDestination.PresignRequest.self, from: try #require(request.httpBody))
        #expect(sent == .init(key: descriptor.key, contentType: "audio/mp4", contentLength: 1234, sha256: "ab"))

        #expect(prepared.method == "PUT")
        #expect(prepared.headers["Content-Type"] == "audio/mp4")
        #expect(prepared.url.host == "acc.r2.cloudflarestorage.com")
    }

    @Test func rejectionBecomesError() async {
        let http = RecordingHTTP(response: (Data("nope".utf8), 401))
        let destination = WorkerPresignDestination(id: "r2", endpoint: URL(string: "https://x.dev")!, http: http) { "t" }
        await #expect(throws: DestinationError.presignRejected(status: 401, body: "nope")) {
            _ = try await destination.prepareUpload(descriptor)
        }
    }

    @Test func factorySkipsDisabledAndNeedsToken() async {
        let tokens = InMemoryTokenStore()
        let configs = [
            DestinationConfig(id: "a", displayName: "A", endpoint: URL(string: "https://a.dev")!),
            DestinationConfig(id: "b", displayName: "B", endpoint: URL(string: "https://b.dev")!, enabled: false),
        ]
        let made = DestinationFactory.make(configs, tokens: tokens, http: RecordingHTTP(response: (Data(), 200)))
        #expect(made.map(\.id) == ["a"])
        await #expect(throws: DestinationError.missingToken("a")) {
            _ = try await made[0].prepareUpload(descriptor)
        }
    }
}
