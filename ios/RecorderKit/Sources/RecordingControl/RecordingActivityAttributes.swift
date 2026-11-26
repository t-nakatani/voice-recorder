import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// ロック画面とダイナミックアイランドに出す「録音中」表示の中身。アプリとウィジェット拡張で共有する。
public struct RecordingActivityAttributes: Codable, Hashable, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var startedAt: Date
        public var isPaused: Bool
        /// 送れた区切り数 / 閉じた区切り数（主宛先）
        public var uploadedSegments: Int
        public var totalSegments: Int
        /// 止めた時刻。入っていれば表示の時間を止める（無ければ開始からの経過を数え続ける）
        public var endedAt: Date?

        public init(startedAt: Date, isPaused: Bool = false, uploadedSegments: Int = 0, totalSegments: Int = 0,
                    endedAt: Date? = nil) {
            self.endedAt = endedAt
            self.startedAt = startedAt
            self.isPaused = isPaused
            self.uploadedSegments = uploadedSegments
            self.totalSegments = totalSegments
        }
    }

    public var recordingID: String

    public init(recordingID: String) { self.recordingID = recordingID }
}

#if canImport(ActivityKit) && os(iOS)
extension RecordingActivityAttributes: ActivityAttributes {}
#endif
