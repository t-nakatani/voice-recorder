import AudioCapture
import BackgroundTransport
import Destinations
import Foundation
import RecorderCore
import RecordingControl
import SegmentStore
import UploadQueue

/// 実機用の組み立て。保存先・宛先・送信・録音・Live Activity をつないで RecordingService を作る。
/// 部品を差し替えたいとき（テスト・プレビュー）は RecordingService の init を直接使う。
public enum AppEnvironment {
    public struct Settings: Sendable {
        public var appGroup: String
        public var keychainService: String
        public var segmentDuration: TimeInterval
        public var retention: RetentionPolicy

        public init(appGroup: String, keychainService: String, segmentDuration: TimeInterval = 30,
                    retention: RetentionPolicy = .keepForever) {
            self.appGroup = appGroup
            self.keychainService = keychainService
            self.segmentDuration = segmentDuration
            self.retention = retention
        }
    }

    public struct Built {
        public let service: RecordingService
        public let transport: BackgroundURLSessionTransport
        public let tokens: TokenStore
        public let destinationConfigs: DestinationConfigRepository
    }

    @MainActor
    public static func make(_ settings: Settings) throws -> Built {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: settings.appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = try FileRecordingStore(root: container.appendingPathComponent("Recorder", isDirectory: true))
        let ledger = try FileDeliveryLedger(root: container.appendingPathComponent("Recorder/deliveries", isDirectory: true))

        let tokens = KeychainTokenStore(service: settings.keychainService)
        let configs = DestinationConfigRepository(suiteName: settings.appGroup)
        let destinations = DestinationFactory.make(configs.load(), tokens: tokens)

        let transport = BackgroundURLSessionTransport(sharedContainerIdentifier: settings.appGroup)
        let scheduler = UploadScheduler(store: store, ledger: ledger, destinations: destinations, transport: transport)

        // ロック中（アプリが裏にいるまま）でも始められる AVAudioRecorder を先に使い、だめなら AVAudioEngine で試す
        let capture = FallbackAudioCapture(settings: .init(segmentDuration: settings.segmentDuration))
        #if os(iOS)
        let activity: RecordingActivityPresenting = LiveActivityController()
        #else
        let activity: RecordingActivityPresenting = NoopActivityPresenter()
        #endif

        let service = RecordingService(store: store, ledger: ledger, scheduler: scheduler, capture: capture,
                                       activity: activity, retention: settings.retention,
                                       pendingStart: PendingStartFlag(suiteName: settings.appGroup),
                                       levels: SegmentLevelStore(suiteName: settings.appGroup))
        capture.onSegmentLevel = { [weak service] index, peak in
            Task { @MainActor in service?.noteSegmentLevel(index: index, peakDBFS: peak) }
        }
        RecordingCommandCenter.shared.handler = service
        return Built(service: service, transport: transport, tokens: tokens, destinationConfigs: configs)
    }

    /// 設定画面で宛先を変えたあとに呼ぶ。
    public static func reloadDestinations(_ built: Built) async {
        let destinations = DestinationFactory.make(built.destinationConfigs.load(), tokens: built.tokens)
        await built.service.scheduler.replaceDestinations(destinations)
        await built.service.kickUploads()
    }
}
