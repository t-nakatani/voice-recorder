import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// 録音中の Live Activity を出す・更新する・消す。
/// AudioRecordingIntent で録音する場合、Apple の決まりで録音中はずっと Live Activity を出しておく必要がある。
public protocol RecordingActivityPresenting: AnyObject, Sendable {
    func begin(recordingID: String, state: RecordingActivityAttributes.ContentState) throws
    func update(_ state: RecordingActivityAttributes.ContentState) async
    /// その録音の Live Activity を全部終わらせてすぐ消す。state があれば最後の表示にする
    func end(recordingID: String, state: RecordingActivityAttributes.ContentState?) async
    /// 録音していないのに残っている Live Activity を全部消す（落ちた・別プロセスで出した等）
    func endAll() async
}

#if canImport(ActivityKit) && os(iOS)
public final class LiveActivityController: RecordingActivityPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: Activity<RecordingActivityAttributes>?

    public init() {}

    public func begin(recordingID: String, state: RecordingActivityAttributes.ContentState) throws {
        // 前回の残り（アプリが落ちた等）は消しておく
        for stale in Activity<RecordingActivityAttributes>.activities where stale.attributes.recordingID != recordingID {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        let created = try Activity.request(
            attributes: RecordingActivityAttributes(recordingID: recordingID),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
        lock.withLock { activity = created }
    }

    public func update(_ state: RecordingActivityAttributes.ContentState) async {
        let current = lock.withLock { activity }
        await current?.update(ActivityContent(state: state, staleDate: nil))
    }

    public func end(recordingID: String, state: RecordingActivityAttributes.ContentState?) async {
        lock.withLock { activity = nil }
        // 覚えている1つだけでなく、その録音のものを全部終わらせる（別のプロセスや前の起動で出したものも含む）。
        // .default だと終わった後もロック画面に最大4時間残るので、すぐ消す
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        for item in Activity<RecordingActivityAttributes>.activities where item.attributes.recordingID == recordingID {
            await item.end(content, dismissalPolicy: .immediate)
        }
    }

    public func endAll() async {
        lock.withLock { activity = nil }
        for item in Activity<RecordingActivityAttributes>.activities {
            await item.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif

/// Live Activity を使わない環境（macOS のテスト等）用。
public final class NoopActivityPresenter: RecordingActivityPresenting, @unchecked Sendable {
    public init() {}
    public func begin(recordingID: String, state: RecordingActivityAttributes.ContentState) throws {}
    public func update(_ state: RecordingActivityAttributes.ContentState) async {}
    public func end(recordingID: String, state: RecordingActivityAttributes.ContentState?) async {}
    public func endAll() async {}
}
