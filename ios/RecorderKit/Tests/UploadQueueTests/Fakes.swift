import Foundation
import RecorderCore
@testable import UploadQueue

/// テスト用の RecordingStore。ファイルは一時ディレクトリに実際に書く（ハッシュ計算のため）。
final class FakeStore: RecordingStore, @unchecked Sendable {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString)")
    private var recordings: [RecordingID: Recording] = [:]
    private let lock = NSLock()

    init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func add(_ id: String, segments: Int, closed: Bool) -> Recording {
        let rid = RecordingID(rawValue: id)
        var recording = Recording(id: rid, startedAt: Date(timeIntervalSince1970: 0), status: closed ? .finished : .recording,
                                  format: .aacMono64k)
        for index in 0..<segments {
            recording.segments.append(Segment(index: index, fileName: "\(index)", startOffset: Double(index) * 30,
                                              duration: 30, byteCount: 3, sha256: "hash\(index)", committedAt: Date()))
            try? Data("abc".utf8).write(to: dir.appendingPathComponent("\(id)-\(index)"))
        }
        if closed { try? Data("{}".utf8).write(to: dir.appendingPathComponent("\(id)-manifest")) }
        lock.withLock { recordings[rid] = recording }
        return recording
    }

    func createRecording(id: RecordingID, startedAt: Date, format: AudioFormat) throws -> Recording { fatalError() }
    func pendingSegmentURL(recordingID: RecordingID, index: Int) throws -> URL { fatalError() }
    func commitSegment(recordingID: RecordingID, index: Int, startOffset: TimeInterval, duration: TimeInterval) throws -> Segment { fatalError() }
    func closeRecording(id: RecordingID, endedAt: Date, status: RecordingStatus, stopReason: StopReason?) throws -> Recording { fatalError() }
    func recording(id: RecordingID) throws -> Recording? { lock.withLock { recordings[id] } }
    func allRecordings() throws -> [Recording] { lock.withLock { Array(recordings.values) } }
    func fileURL(for item: UploadItem, of recordingID: RecordingID) throws -> URL {
        switch item {
        case .segment(let index): return dir.appendingPathComponent("\(recordingID.rawValue)-\(index)")
        case .manifest: return dir.appendingPathComponent("\(recordingID.rawValue)-manifest")
        }
    }
    func deleteRecording(id: RecordingID) throws { lock.withLock { recordings[id] = nil } }
}

struct FakeDestination: Destination {
    let id: DestinationID
    var fail = false
    func prepareUpload(_ descriptor: UploadDescriptor) async throws -> PreparedUpload {
        if fail { throw URLError(.notConnectedToInternet) }
        return PreparedUpload(url: URL(string: "https://example.invalid/\(id.rawValue)/\(descriptor.key)")!,
                              expiresAt: Date().addingTimeInterval(900))
    }
}

final class FakeTransport: UploadTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private(set) var startedTokens: [String] = []
    var active: Set<String> = []

    init() {
        var continuation: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func startUpload(_ prepared: PreparedUpload, fileURL: URL, jobToken: String) async throws {
        lock.withLock {
            startedTokens.append(jobToken)
            active.insert(jobToken)
        }
    }

    func activeJobTokens() async -> Set<String> { lock.withLock { active } }

    var started: [String] { lock.withLock { startedTokens } }
}

final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
