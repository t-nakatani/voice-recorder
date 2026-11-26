import Foundation

/// ロック中は停止ボタンを押すと Face ID を求められる（iOS の仕様）。そのため、ロック解除なしでも
/// 録音が終わるように、無音が続いたときと長さの上限で自動的に止める。値はここだけで決める。
public struct AutoStopPolicy: Sendable, Equatable {
    /// これより小さい最大音量（dBFS）を無音とみなす
    public var silenceThresholdDBFS: Double
    /// 無音がこれだけ続いたら止める
    public var silenceDuration: TimeInterval
    /// 録音の長さの上限
    public var maxDuration: TimeInterval

    public init(silenceThresholdDBFS: Double = -50, silenceDuration: TimeInterval = 5 * 60,
                maxDuration: TimeInterval = 3 * 60 * 60) {
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.silenceDuration = silenceDuration
        self.maxDuration = maxDuration
    }

    public static let standard = AutoStopPolicy()
}

public enum StopReason: String, Codable, Sendable, Equatable {
    case user
    case silence = "auto: silence"
    case maxDuration = "auto: max duration"
}

/// 1つの録音について、音量の知らせと時刻から「自動で止めるか」を決める。時刻は呼び出し側が渡す（テストで差し替えられる）。
public struct AutoStopMonitor: Sendable {
    public let policy: AutoStopPolicy
    public let startedAt: Date
    /// 最後に無音でない音を聞いた時刻（始めた時刻から数える）
    public private(set) var lastSoundAt: Date
    /// 電話などで止まっている間は、無音を数えない
    public private(set) var isPaused = false

    public init(policy: AutoStopPolicy, startedAt: Date) {
        self.policy = policy
        self.startedAt = startedAt
        lastSoundAt = startedAt
    }

    public mutating func noteLevel(_ peakDBFS: Double, at time: Date) {
        if peakDBFS >= policy.silenceThresholdDBFS { lastSoundAt = max(lastSoundAt, time) }
    }

    public mutating func notePaused(at time: Date) { isPaused = true }

    /// 再開した時点から無音を数え直す
    public mutating func noteResumed(at time: Date) {
        isPaused = false
        lastSoundAt = max(lastSoundAt, time)
    }

    public func check(now: Date) -> StopReason? {
        if now.timeIntervalSince(startedAt) >= policy.maxDuration { return .maxDuration }
        if !isPaused, now.timeIntervalSince(lastSoundAt) >= policy.silenceDuration { return .silence }
        return nil
    }
}
