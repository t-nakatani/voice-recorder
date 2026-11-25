import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// 録音中の Live Activity を出す・更新する・消す。
/// AudioRecordingIntent で録音する場合、Apple の決まりで録音中はずっと Live Activity を出しておく必要がある。
public protocol RecordingActivityPresenting: AnyObject, Sendable {
    func begin(recordingID: String, state: RecordingActivityAttributes.ContentState) throws
    func update(_ state: RecordingActivityAttributes.ContentState) async
    func end(_ state: RecordingActivityAttributes.ContentState?) async
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

    public func end(_ state: RecordingActivityAttributes.ContentState?) async {
        let current = lock.withLock { () -> Activity<RecordingActivityAttributes>? in
            defer { activity = nil }
            return activity
        }
        await current?.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: .default)
    }
}
#endif

/// Live Activity を使わない環境（macOS のテスト等）用。
public final class NoopActivityPresenter: RecordingActivityPresenting, @unchecked Sendable {
    public init() {}
    public func begin(recordingID: String, state: RecordingActivityAttributes.ContentState) throws {}
    public func update(_ state: RecordingActivityAttributes.ContentState) async {}
    public func end(_ state: RecordingActivityAttributes.ContentState?) async {}
}
