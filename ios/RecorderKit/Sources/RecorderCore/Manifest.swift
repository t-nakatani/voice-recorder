import Foundation

/// 録音終了時に最後に送る目録。サーバー側はこれを見て「区切りが全部そろった」と判断する。
public struct RecordingManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var index: Int
        public var key: String
        public var startOffset: TimeInterval
        public var duration: TimeInterval
        public var byteCount: Int64
        public var sha256: String
    }

    public var version: Int
    public var recordingID: RecordingID
    public var status: RecordingStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var totalDuration: TimeInterval
    public var format: AudioFormat
    public var segments: [Entry]
    /// なぜ止まったか。"user" / "auto: silence" / "auto: max duration"。不明なら書かない
    public var stopReason: StopReason?

    public init(recording: Recording) {
        version = 1
        recordingID = recording.id
        status = recording.status
        startedAt = recording.startedAt
        endedAt = recording.endedAt
        totalDuration = recording.totalDuration
        format = recording.format
        stopReason = recording.stopReason
        segments = recording.segments.sorted { $0.index < $1.index }.map {
            Entry(index: $0.index,
                  key: ObjectKeys.segment(recording.id, index: $0.index, fileExtension: recording.format.fileExtension),
                  startOffset: $0.startOffset, duration: $0.duration, byteCount: $0.byteCount, sha256: $0.sha256)
        }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
