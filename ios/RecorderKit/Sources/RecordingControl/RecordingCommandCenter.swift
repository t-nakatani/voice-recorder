import Foundation

/// 録音を始めた経路。ログと、スパイクでの比較に使う。
public enum RecordingTrigger: String, Codable, Sendable {
    case inApp
    /// ロック画面・コントロールセンター・アクションボタンから（ロック解除なし）
    case controlWithoutUnlock
    /// コントロールからアプリを開いて開始（Face ID が挟まる）
    case controlOpenApp
    case shortcut
}

/// App Intents（ウィジェット拡張とアプリの両方で動く）から、アプリ本体の録音処理を呼ぶための窓口。
/// RecordingControl は RecorderRuntime に依存しないよう、ここに protocol だけを置く。
public protocol RecordingCommandHandling: AnyObject, Sendable {
    /// 始め方の短いメモ（どの方法で録り始めたか、Live Activity、アプリの状態）を返す。intent の記録に残す
    @discardableResult
    func startRecording(trigger: RecordingTrigger) async throws -> String
    func stopRecording() async throws
}

public enum RecordingCommandError: Error, CustomStringConvertible {
    /// ウィジェット拡張のプロセスで intent が実行された（アプリ本体が起きていない）
    case handlerUnavailable

    public var description: String {
        switch self {
        case .handlerUnavailable: return "録音アプリ本体が応答しませんでした"
        }
    }
}

public final class RecordingCommandCenter: @unchecked Sendable {
    public static let shared = RecordingCommandCenter()

    private let lock = NSLock()
    private var _handler: RecordingCommandHandling?

    /// アプリ起動時（App の init）に登録する。intent で起こされたときも App の init は走る。
    public var handler: RecordingCommandHandling? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    public func requireHandler() throws -> RecordingCommandHandling {
        guard let handler else { throw RecordingCommandError.handlerUnavailable }
        return handler
    }
}

/// 「アプリを開いたら録音を始めて」という印（方式B）。App Group の UserDefaults に置く。
public struct PendingStartFlag: Sendable {
    private let suiteName: String?
    private let key = "pendingStart.requestedAt"
    /// 印をつけてからこの秒数以内にアプリが前面に来たら録音を始める
    public var validFor: TimeInterval = 60

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func raise(at date: Date = Date()) { defaults.set(date.timeIntervalSince1970, forKey: key) }

    /// 有効な印があれば消して true を返す。
    public func consume(now: Date = Date()) -> Bool {
        let raw = defaults.double(forKey: key)
        defaults.removeObject(forKey: key)
        guard raw > 0 else { return false }
        return now.timeIntervalSince1970 - raw <= validFor
    }
}
