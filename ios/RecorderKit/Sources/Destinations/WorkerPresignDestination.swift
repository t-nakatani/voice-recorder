import Foundation
import RecorderCore

/// Cloudflare Worker（../ingest）に署名付きURLを発行してもらう宛先。
///
/// 流れ: `POST {endpoint}/v1/presign` に端末トークン付きで「このキーにこのファイルを置きたい」と送る
/// → Worker が R2（S3互換API）用の期限付き PUT URL を返す → それを UploadTransport が使う。
/// バケットの鍵は iPhone に置かない。端末トークンは Worker 側で無効にできる。
public struct WorkerPresignDestination: Destination {
    public let id: DestinationID
    public let endpoint: URL
    private let tokenProvider: @Sendable () throws -> String
    private let http: HTTPClient

    public init(id: DestinationID, endpoint: URL, http: HTTPClient = URLSessionHTTPClient(),
                tokenProvider: @escaping @Sendable () throws -> String) {
        self.id = id
        self.endpoint = endpoint
        self.http = http
        self.tokenProvider = tokenProvider
    }

    public func prepareUpload(_ descriptor: UploadDescriptor) async throws -> PreparedUpload {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/presign"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try tokenProvider())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(PresignRequest(
            key: descriptor.key, contentType: descriptor.contentType,
            contentLength: descriptor.byteCount, sha256: descriptor.sha256Hex
        ))

        let (data, status) = try await http.send(request)
        guard (200..<300).contains(status) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw DestinationError.presignRejected(status: status, body: body)
        }
        let response = try Self.decoder.decode(PresignResponse.self, from: data)
        guard let url = URL(string: response.url) else { throw DestinationError.invalidResponse }
        return PreparedUpload(url: url, method: response.method, headers: response.headers, expiresAt: response.expiresAt)
    }

    struct PresignRequest: Codable, Equatable {
        var key: String
        var contentType: String
        var contentLength: Int64
        var sha256: String
    }

    struct PresignResponse: Codable {
        var url: String
        var method: String
        var headers: [String: String]
        var expiresAt: Date
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum DestinationError: Error, Equatable, CustomStringConvertible {
    case presignRejected(status: Int, body: String)
    case invalidResponse
    case missingToken(DestinationID)

    public var description: String {
        switch self {
        case .presignRejected(let status, let body): return "署名付きURLの発行を断られました (HTTP \(status)) \(body)"
        case .invalidResponse: return "署名付きURLの応答を読めませんでした"
        case .missingToken(let id): return "宛先 \(id) の端末トークンが設定されていません"
        }
    }
}

/// 署名付きURLの発行に使う HTTP。テストでは偽物に差し替える。
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
