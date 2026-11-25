import Foundation
import RecorderCore

/// 配送状態の台帳。録音ごとに1ファイル（root/<録音ID>.json）で持つ。
public protocol DeliveryLedger: AnyObject, Sendable {
    func state(of job: UploadJob) -> DeliveryState
    func set(_ state: DeliveryState, for job: UploadJob) throws
    func states(for recordingID: RecordingID) -> [UploadJob: DeliveryState]
    func removeAll(for recordingID: RecordingID) throws
}

public final class FileDeliveryLedger: DeliveryLedger, @unchecked Sendable {
    private struct Row: Codable {
        var item: UploadItem
        var destination: DestinationID
        var state: DeliveryState
    }

    private let root: URL
    private let lock = NSLock()
    private var cache: [RecordingID: [UploadJob: DeliveryState]] = [:]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
    }

    public func state(of job: UploadJob) -> DeliveryState {
        lock.withLock { load(job.recordingID)[job] ?? .pending }
    }

    public func set(_ state: DeliveryState, for job: UploadJob) throws {
        try lock.withLock {
            var rows = load(job.recordingID)
            rows[job] = state
            cache[job.recordingID] = rows
            try save(job.recordingID, rows)
        }
    }

    public func states(for recordingID: RecordingID) -> [UploadJob: DeliveryState] {
        lock.withLock { load(recordingID) }
    }

    public func removeAll(for recordingID: RecordingID) throws {
        try lock.withLock {
            cache[recordingID] = nil
            let url = fileURL(recordingID)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func fileURL(_ id: RecordingID) -> URL { root.appendingPathComponent("\(id.rawValue).json") }

    private func load(_ id: RecordingID) -> [UploadJob: DeliveryState] {
        if let cached = cache[id] { return cached }
        var result: [UploadJob: DeliveryState] = [:]
        if let data = FileManager.default.contents(atPath: fileURL(id).path),
           let rows = try? Self.decoder.decode([Row].self, from: data) {
            for row in rows {
                result[UploadJob(recordingID: id, item: row.item, destination: row.destination)] = row.state
            }
        }
        cache[id] = result
        return result
    }

    private func save(_ id: RecordingID, _ rows: [UploadJob: DeliveryState]) throws {
        let list = rows.map { Row(item: $0.key.item, destination: $0.key.destination, state: $0.value) }
            .sorted { "\($0.item)\($0.destination)" < "\($1.item)\($1.destination)" }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try Self.encoder.encode(list).write(to: fileURL(id), options: options)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// テストやプレビュー用のメモリ版。
public final class InMemoryDeliveryLedger: DeliveryLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [UploadJob: DeliveryState] = [:]
    public init() {}
    public func state(of job: UploadJob) -> DeliveryState { lock.withLock { rows[job] ?? .pending } }
    public func set(_ state: DeliveryState, for job: UploadJob) throws { lock.withLock { rows[job] = state } }
    public func states(for recordingID: RecordingID) -> [UploadJob: DeliveryState] {
        lock.withLock { rows.filter { $0.key.recordingID == recordingID } }
    }
    public func removeAll(for recordingID: RecordingID) throws {
        lock.withLock { rows = rows.filter { $0.key.recordingID != recordingID } }
    }
}
