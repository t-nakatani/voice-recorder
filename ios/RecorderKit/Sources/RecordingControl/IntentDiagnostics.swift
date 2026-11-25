import Foundation
import os

/// App Intents がどのプロセスで動き、どう終わったかの記録。
/// 端末のログを取れないときでも、アプリの画面で確かめられるように App Group の UserDefaults に残す。
public struct IntentBreadcrumb: Codable, Sendable, Equatable {
    public var at: Date
    public var intent: String
    /// 実行したプロセスのバンドルID（アプリ本体か、ウィジェット拡張か）
    public var process: String
    public var handlerAvailable: Bool
    /// "ok" か、失敗の内容
    public var outcome: String

    public init(at: Date, intent: String, process: String, handlerAvailable: Bool, outcome: String) {
        self.at = at
        self.intent = intent
        self.process = process
        self.handlerAvailable = handlerAvailable
        self.outcome = outcome
    }
}

public struct IntentDiagnostics: Sendable {
    public static let logger = Logger(subsystem: "com.uniedge-labs.voicerecorder", category: "intent")
    private let suiteName: String?
    private let key = "diagnostics.intents.v1"
    /// 残す件数
    public var limit = 30

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public static var currentProcess: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    public func record(_ crumb: IntentBreadcrumb) {
        Self.logger.notice("""
            intent=\(crumb.intent, privacy: .public) process=\(crumb.process, privacy: .public) \
            handler=\(crumb.handlerAvailable, privacy: .public) outcome=\(crumb.outcome, privacy: .public)
            """)
        var all = recent()
        all.insert(crumb, at: 0)
        if all.count > limit { all.removeLast(all.count - limit) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    /// 新しい順
    public func recent() -> [IntentBreadcrumb] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IntentBreadcrumb].self, from: data)) ?? []
    }
}

/// ウィジェット拡張のプロセスで止める intent が動いたとき、録音しているアプリ本体へ「止めて」を伝える。
/// Darwin 通知はプロセスをまたいで届く（同じ端末の中だけ。中身は運べないので名前だけで伝える）。
public enum CrossProcessCommand: String, Sendable {
    case stop = "com.uniedge-labs.voicerecorder.command.stop"

    public func post() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(rawValue as CFString), nil, nil, true)
    }

    /// アプリ本体で1回だけ呼ぶ。通知が来たら handler を main で呼ぶ。
    public func observe(_ handler: @escaping @Sendable () -> Void) {
        CrossProcessObservers.shared.add(self, handler)
    }
}

final class CrossProcessObservers: @unchecked Sendable {
    static let shared = CrossProcessObservers()
    private let lock = NSLock()
    private var handlers: [String: @Sendable () -> Void] = [:]

    func add(_ command: CrossProcessCommand, _ handler: @escaping @Sendable () -> Void) {
        let isNew = lock.withLock { () -> Bool in
            let isNew = handlers[command.rawValue] == nil
            handlers[command.rawValue] = handler
            return isNew
        }
        guard isNew else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let me = Unmanaged<CrossProcessObservers>.fromOpaque(observer).takeUnretainedValue()
            me.fire(name.rawValue as String)
        }, command.rawValue as CFString, nil, .deliverImmediately)
    }

    private func fire(_ name: String) {
        let handler = lock.withLock { handlers[name] }
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }
}
