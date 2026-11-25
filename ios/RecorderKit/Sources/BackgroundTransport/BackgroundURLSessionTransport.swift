import Foundation
import RecorderCore

/// バックグラウンド URLSession で送る UploadTransport。
///
/// - ファイルから送るので、アプリが閉じていても iOS が代わりに送り、電波が戻れば続きを送る
/// - どのジョブかは taskDescription に UploadJob.token を入れて対応づける
/// - アプリが送信完了で起こされたときは AppDelegate の
///   `application(_:handleEventsForBackgroundURLSession:completionHandler:)` から
///   `setBackgroundCompletionHandler` に completionHandler を渡すこと
public final class BackgroundURLSessionTransport: NSObject, UploadTransport, @unchecked Sendable {
    public static let defaultIdentifier = "recorder.upload.background"

    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var backgroundCompletionHandler: (() -> Void)?
    private var session: URLSession!

    /// - Parameters:
    ///   - identifier: アプリ内で1つに固定する（変えると送信中のタスクを見失う）
    ///   - sharedContainerIdentifier: App Group。拡張から送る場合に必要
    public init(identifier: String = BackgroundURLSessionTransport.defaultIdentifier,
                sharedContainerIdentifier: String? = nil) {
        var continuation: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        super.init()

        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = sharedContainerIdentifier
        configuration.sessionSendsLaunchEvents = true
        // 録音中・ロック中でもすぐ送ってほしいので「OS任せ」にはしない（Wi-Fi待ちにしない）
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.withLock { backgroundCompletionHandler = handler }
    }

    public func startUpload(_ prepared: PreparedUpload, fileURL: URL, jobToken: String) async throws {
        let task = session.uploadTask(with: prepared.urlRequest(), fromFile: fileURL)
        task.taskDescription = jobToken
        task.resume()
    }

    public func activeJobTokens() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }
}

extension BackgroundURLSessionTransport: URLSessionTaskDelegate, URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let token = task.taskDescription else { return }
        if let error {
            continuation.yield(.failed(jobToken: token, message: error.localizedDescription))
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        continuation.yield(.completed(jobToken: token, statusCode: status))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            defer { backgroundCompletionHandler = nil }
            return backgroundCompletionHandler
        }
        DispatchQueue.main.async { handler?() }
    }
}
