import Foundation
import RecorderCore

/// テストと画面確認用の送信部品。送ったものを覚えておき、結果は手で返す。
public final class InMemoryTransport: UploadTransport, @unchecked Sendable {
    public struct Started: Equatable, Sendable {
        public var prepared: PreparedUpload
        public var fileURL: URL
        public var jobToken: String
    }

    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var active: Set<String> = []
    public private(set) var started: [Started] = []
    public var failStartWith: Error?

    public init() {
        var continuation: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
    }

    public func startUpload(_ prepared: PreparedUpload, fileURL: URL, jobToken: String) async throws {
        if let failStartWith { throw failStartWith }
        lock.withLock {
            started.append(Started(prepared: prepared, fileURL: fileURL, jobToken: jobToken))
            active.insert(jobToken)
        }
    }

    public func activeJobTokens() async -> Set<String> { lock.withLock { active } }

    public func finish(_ token: String, status: Int) {
        _ = lock.withLock { active.remove(token) }
        continuation.yield(.completed(jobToken: token, statusCode: status))
    }

    public func forgetAll() { lock.withLock { active.removeAll() } }
}
