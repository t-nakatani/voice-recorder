import Foundation
import RecorderCore

/// 区切りごとの最大音量（dBFS）を残す。確認用なので、新しい録音から決まった数だけ持つ。
public struct SegmentLevelStore: Sendable {
    private let suiteName: String?
    private let key = "diagnostics.segmentPeaks.v1"
    public var keepRecordings = 50

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> [RecordingID: [Int: Double]] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: [String: Double]] else { return [:] }
        var out: [RecordingID: [Int: Double]] = [:]
        for (id, perIndex) in raw {
            out[RecordingID(rawValue: id)] = Dictionary(uniqueKeysWithValues: perIndex.compactMap { k, v in
                Int(k).map { ($0, v) }
            })
        }
        return out
    }

    public func save(_ peaks: [RecordingID: [Int: Double]]) {
        // 録音IDは開始時刻で始まるので、名前の順が新しさの順になる
        let kept = peaks.keys.map(\.rawValue).sorted().suffix(keepRecordings)
        var raw: [String: [String: Double]] = [:]
        for id in kept {
            // -infinity は plist に入らないので、十分小さい値にする
            raw[id] = Dictionary(uniqueKeysWithValues: (peaks[RecordingID(rawValue: id)] ?? [:]).map {
                (String($0.key), $0.value.isFinite ? $0.value : -200)
            })
        }
        defaults.set(raw, forKey: key)
    }
}
