import Foundation
import RecorderCore

/// iPhone 上の録音をいつ消してよいかの判断。既定は「消さない」。
/// 消してよいのは「閉じた録音」で「全宛先に全部届いた」かつ「保持期間を過ぎた」ものだけ。
public struct RetentionPolicy: Sendable, Equatable {
    /// nil なら自動では消さない
    public var keepDeliveredFor: TimeInterval?

    public init(keepDeliveredFor: TimeInterval? = nil) {
        self.keepDeliveredFor = keepDeliveredFor
    }

    public static let keepForever = RetentionPolicy(keepDeliveredFor: nil)

    public func mayDelete(_ recording: Recording, fullyDelivered: Bool, now: Date) -> Bool {
        guard let keep = keepDeliveredFor, recording.isClosed, fullyDelivered else { return false }
        let reference = recording.endedAt ?? recording.startedAt
        return now.timeIntervalSince(reference) >= keep
    }
}
