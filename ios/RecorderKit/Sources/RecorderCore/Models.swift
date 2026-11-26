import Foundation

/// 録音ファイルの形式。区切りファイルはすべて同じ形式で書く。
public struct AudioFormat: Codable, Equatable, Sendable {
    public var fileExtension: String
    public var contentType: String
    public var sampleRate: Double
    public var channels: Int
    public var bitRate: Int

    public init(fileExtension: String, contentType: String, sampleRate: Double, channels: Int, bitRate: Int) {
        self.fileExtension = fileExtension
        self.contentType = contentType
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
    }

    /// 既定: AAC 64kbps モノラル（1分あたり約0.5MB）。
    public static let aacMono64k = AudioFormat(
        fileExtension: "m4a", contentType: "audio/mp4", sampleRate: 48_000, channels: 1, bitRate: 64_000
    )
}

/// 書き終えて閉じた区切りファイル1つ。台帳に載った時点で実ファイルが必ず存在する。
public struct Segment: Codable, Equatable, Sendable {
    public var index: Int
    public var fileName: String
    /// 録音開始からの開始位置（秒）
    public var startOffset: TimeInterval
    public var duration: TimeInterval
    public var byteCount: Int64
    /// ファイル内容の SHA-256（小文字16進）
    public var sha256: String
    public var committedAt: Date

    public init(index: Int, fileName: String, startOffset: TimeInterval, duration: TimeInterval,
                byteCount: Int64, sha256: String, committedAt: Date) {
        self.index = index
        self.fileName = fileName
        self.startOffset = startOffset
        self.duration = duration
        self.byteCount = byteCount
        self.sha256 = sha256
        self.committedAt = committedAt
    }
}

public enum RecordingStatus: String, Codable, Sendable {
    /// 録音中（アプリが落ちて残ったものは起動時に interrupted へ直す）
    case recording
    /// 停止ボタンで正常に終わった
    case finished
    /// アプリの終了などで途中で切れたが、そこまでの区切りは残っている
    case interrupted
}

/// 録音1回分の台帳。
public struct Recording: Codable, Equatable, Sendable, Identifiable {
    public var id: RecordingID
    public var startedAt: Date
    public var endedAt: Date?
    public var status: RecordingStatus
    public var format: AudioFormat
    public var segments: [Segment]
    /// なぜ止まったか（手で止めた・無音が続いた・長さの上限）。古い台帳には無い
    public var stopReason: StopReason?

    public init(id: RecordingID, startedAt: Date, endedAt: Date? = nil, status: RecordingStatus,
                format: AudioFormat, segments: [Segment] = []) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.format = format
        self.segments = segments
    }

    public var isClosed: Bool { status != .recording }
    public var totalDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    public var nextSegmentIndex: Int { (segments.map(\.index).max() ?? -1) + 1 }
}

/// 送るもの。区切りファイルか、録音終了後の manifest。
public enum UploadItem: Hashable, Codable, Sendable, CustomStringConvertible {
    case segment(Int)
    case manifest

    public var description: String {
        switch self {
        case .segment(let index): return "segment-\(index)"
        case .manifest: return "manifest"
        }
    }
}

/// 「どの録音の、どれを、どの宛先へ」。送信の最小単位。
public struct UploadJob: Hashable, Codable, Sendable, CustomStringConvertible {
    public var recordingID: RecordingID
    public var item: UploadItem
    public var destination: DestinationID

    public init(recordingID: RecordingID, item: UploadItem, destination: DestinationID) {
        self.recordingID = recordingID
        self.item = item
        self.destination = destination
    }

    /// URLSession の taskDescription などに入れる文字列表現。
    public var token: String { "\(recordingID.rawValue)|\(item)|\(destination.rawValue)" }

    public init?(token: String) {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let item: UploadItem
        if parts[1] == "manifest" {
            item = .manifest
        } else if parts[1].hasPrefix("segment-"), let index = Int(parts[1].dropFirst("segment-".count)) {
            item = .segment(index)
        } else {
            return nil
        }
        self.init(recordingID: RecordingID(rawValue: parts[0]), item: item, destination: DestinationID(rawValue: parts[2]))
    }

    public var description: String { token }
}
