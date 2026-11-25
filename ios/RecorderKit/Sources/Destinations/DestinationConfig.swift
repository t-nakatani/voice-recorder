import Foundation
import RecorderCore

/// 宛先の設定（UserDefaults などに JSON で保存する）。トークンはここに入れず Keychain に置く。
public struct DestinationConfig: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// ../ingest の /v1/presign を持つエンドポイント
        case workerPresign
    }

    public var id: DestinationID
    public var kind: Kind
    public var displayName: String
    public var endpoint: URL
    public var enabled: Bool

    public init(id: DestinationID, kind: Kind = .workerPresign, displayName: String, endpoint: URL, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.endpoint = endpoint
        self.enabled = enabled
    }
}

public enum DestinationFactory {
    /// 設定から宛先の実装を作る。新しい種類を足すときはここに case を足すだけ。
    public static func make(_ configs: [DestinationConfig], tokens: TokenStore,
                            http: HTTPClient = URLSessionHTTPClient()) -> [Destination] {
        configs.filter(\.enabled).map { config -> Destination in
            switch config.kind {
            case .workerPresign:
                let id = config.id
                return WorkerPresignDestination(id: id, endpoint: config.endpoint, http: http) {
                    guard let token = try tokens.token(for: id) else { throw DestinationError.missingToken(id) }
                    return token
                }
            }
        }
    }
}

/// 設定一式を UserDefaults（App Group）に保存する。
public struct DestinationConfigRepository: Sendable {
    private let suiteName: String?
    private let key = "destinations.v1"

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> [DestinationConfig] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DestinationConfig].self, from: data)) ?? []
    }

    public func save(_ configs: [DestinationConfig]) throws {
        defaults.set(try JSONEncoder().encode(configs), forKey: key)
    }
}
