import Foundation

// 部品同士をつなぐ契約。実装はそれぞれのモジュールにあり、RecorderRuntime が組み立てる。
// テストでは各契約を偽物に差し替えて部品単体で検証する。

// MARK: - 保存

/// 録音とその区切りファイルをローカルに保存する。
public protocol RecordingStore: AnyObject, Sendable {
    /// 新しい録音を台帳に作る（status = .recording）。
    func createRecording(id: RecordingID, startedAt: Date, format: AudioFormat) throws -> Recording
    /// 録音部品が区切りを書き込む先のURL。書き終えたら commitSegment を呼ぶ。
    func pendingSegmentURL(recordingID: RecordingID, index: Int) throws -> URL
    /// 書き終えた区切りを台帳に載せる。ハッシュとサイズはここで計算する。
    @discardableResult
    func commitSegment(recordingID: RecordingID, index: Int, startOffset: TimeInterval, duration: TimeInterval) throws -> Segment
    /// 録音を閉じ、manifest.json を書き出す。
    @discardableResult
    func closeRecording(id: RecordingID, endedAt: Date, status: RecordingStatus, stopReason: StopReason?) throws -> Recording
    func recording(id: RecordingID) throws -> Recording?
    func allRecordings() throws -> [Recording]
    /// 送信に使うファイルの場所（区切りファイル、または manifest）。
    func fileURL(for item: UploadItem, of recordingID: RecordingID) throws -> URL
    /// 録音ごと削除する。呼んでよいかの判断は RetentionPolicy が行う。
    func deleteRecording(id: RecordingID) throws
}

// MARK: - 宛先

/// 送信1回分の情報。宛先はこれをもとに署名付きリクエストを用意する。
public struct UploadDescriptor: Equatable, Sendable {
    public var key: String
    public var contentType: String
    public var byteCount: Int64
    public var sha256Hex: String

    public init(key: String, contentType: String, byteCount: Int64, sha256Hex: String) {
        self.key = key
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
    }
}

/// 宛先が用意した「このURLにこのヘッダーで PUT すればよい」という情報。
public struct PreparedUpload: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var expiresAt: Date

    public init(url: URL, method: String = "PUT", headers: [String: String] = [:], expiresAt: Date) {
        self.url = url
        self.method = method
        self.headers = headers
        self.expiresAt = expiresAt
    }

    public func urlRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

/// 転送先。R2 でも S3 でも、署名付きURLを出せるものなら何でもよい。
public protocol Destination: Sendable {
    var id: DestinationID { get }
    func prepareUpload(_ descriptor: UploadDescriptor) async throws -> PreparedUpload
}

// MARK: - 送信

public enum TransportEvent: Equatable, Sendable {
    case completed(jobToken: String, statusCode: Int)
    case failed(jobToken: String, message: String)
}

/// 実際にバイトを送る部品。バックグラウンド URLSession 実装と、テスト用の偽物がある。
public protocol UploadTransport: AnyObject, Sendable {
    /// 送信を開始する（完了は events で届く）。アプリが閉じていても続く前提。
    func startUpload(_ prepared: PreparedUpload, fileURL: URL, jobToken: String) async throws
    /// 今 OS が抱えている送信の jobToken 一覧。起動時の突き合わせに使う。
    func activeJobTokens() async -> Set<String>
    var events: AsyncStream<TransportEvent> { get }
}

// MARK: - 録音

/// 録音部品からの知らせ。
public enum CaptureEvent: Sendable, Equatable {
    /// 区切りファイルを書き終えて閉じた
    case segmentFinished(index: Int, startOffset: TimeInterval, duration: TimeInterval)
    /// 電話などで一時的に止まった
    case interrupted
    /// 割り込みが終わって新しい区切りから再開した
    case resumed
    /// 続行できないエラー。ここまでの区切りは残っている
    case failed(message: String)
}

public protocol AudioCapturing: AnyObject {
    var isRunning: Bool { get }
    /// segmentURL は区切り番号を受け取り、書き込み先を返す。
    func start(firstIndex: Int, segmentURL: @escaping (Int) throws -> URL,
               onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws
    /// 書きかけの区切りを閉じてから止まる（閉じた区切りは segmentFinished で届く）。
    func stop()
}

// MARK: - 時計

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

extension RecordingStore {
    @discardableResult
    public func closeRecording(id: RecordingID, endedAt: Date, status: RecordingStatus) throws -> Recording {
        try closeRecording(id: id, endedAt: endedAt, status: status, stopReason: nil)
    }
}
