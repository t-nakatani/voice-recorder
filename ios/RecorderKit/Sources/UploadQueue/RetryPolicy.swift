import Foundation

/// 失敗したときの待ち時間。諦めずに、間隔を伸ばしながら送り直し続ける。
public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// 0...1。待ち時間をこの割合だけ揺らして、一斉送信を避ける
    public var jitter: Double

    public init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 30 * 60, jitter: Double = 0.2) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// attempts 回失敗したあと、次に試すまでの秒数。
    public func delay(afterAttempts attempts: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = Double(max(0, attempts - 1))
        let raw = min(maxDelay, baseDelay * pow(2, exponent))
        let spread = raw * jitter
        return max(0, raw - spread + 2 * spread * random)
    }
}
