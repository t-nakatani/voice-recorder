import Foundation

/// 「何フレーム書いたら区切りを変えるか」だけを決める純粋なロジック。AVFoundation に依存しないのでテストしやすい。
public struct SegmentPlanner: Sendable, Equatable {
    public let segmentDuration: TimeInterval
    public private(set) var sampleRate: Double
    public private(set) var currentIndex: Int
    public private(set) var framesInCurrent: Int64 = 0
    /// これまでに閉じた区切りの合計秒数（＝次の区切りの開始位置）
    public private(set) var closedDuration: TimeInterval

    public init(segmentDuration: TimeInterval, sampleRate: Double, firstIndex: Int = 0, startOffset: TimeInterval = 0) {
        precondition(segmentDuration > 0 && sampleRate > 0)
        self.segmentDuration = segmentDuration
        self.sampleRate = sampleRate
        self.currentIndex = firstIndex
        self.closedDuration = startOffset
    }

    public var currentStartOffset: TimeInterval { closedDuration }
    public var currentDuration: TimeInterval { Double(framesInCurrent) / sampleRate }

    /// フレームを書いたことを記録する。区切りを閉じるべきなら true。
    public mutating func didWrite(frames: Int) -> Bool {
        framesInCurrent += Int64(frames)
        return currentDuration >= segmentDuration
    }

    /// 今の区切りを閉じ、閉じた区切りの (index, startOffset, duration) を返して次へ進む。
    /// 1フレームも書いていなければ nil（空ファイルは区切りにしない）。
    public mutating func closeCurrent() -> (index: Int, startOffset: TimeInterval, duration: TimeInterval)? {
        defer { framesInCurrent = 0 }
        guard framesInCurrent > 0 else { return nil }
        let closed = (index: currentIndex, startOffset: closedDuration, duration: currentDuration)
        closedDuration += closed.duration
        currentIndex += 1
        return closed
    }

    /// 入力の形式が変わったとき（イヤホンを抜いた等）。閉じた直後に呼ぶ。
    public mutating func updateSampleRate(_ rate: Double) {
        precondition(framesInCurrent == 0, "区切りを閉じてから変える")
        sampleRate = rate
    }
}
