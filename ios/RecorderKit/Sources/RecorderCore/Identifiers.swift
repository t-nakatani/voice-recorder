import Foundation

/// 録音1回を表すID。時刻順に並ぶよう「UTCの時刻 + 乱数」で作る（例: 20261125T091900Z-3f9a2c1b）。
/// オブジェクトキーにそのまま使うので、英数字とハイフンだけで構成する。
public struct RecordingID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func make(at date: Date = Date(), random: UInt32 = UInt32.random(in: .min ... .max)) -> RecordingID {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let suffix = String(format: "%08x", random)
        return RecordingID(rawValue: "\(formatter.string(from: date))-\(suffix)")
    }

    public var description: String { rawValue }
    public static func < (lhs: RecordingID, rhs: RecordingID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 転送先の識別子（例: "r2-primary"）。設定と台帳の両方で使う。
public struct DestinationID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}
