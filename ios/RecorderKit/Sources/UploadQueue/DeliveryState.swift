import Foundation
import RecorderCore

/// 1つの UploadJob（録音 × 送るもの × 宛先）の配送状態。
public enum DeliveryState: Codable, Equatable, Sendable {
    /// まだ送っていない（または送り直す必要がある）
    case pending
    /// OS に送信を頼んだ
    case inFlight(startedAt: Date, attempt: Int)
    /// 宛先が 2xx を返した
    case delivered(at: Date)
    /// 失敗した。nextAttemptAt 以降に送り直す
    case failed(attempts: Int, lastError: String, nextAttemptAt: Date)

    public var isDelivered: Bool { if case .delivered = self { return true } else { return false } }

    public var attempts: Int {
        switch self {
        case .pending, .delivered: return 0
        case .inFlight(_, let attempt): return attempt
        case .failed(let attempts, _, _): return attempts
        }
    }
}
