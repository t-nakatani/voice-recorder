@preconcurrency import AVFoundation
import Foundation

/// AVAudioSession の設定。差し替えられるように protocol にしておく。
public protocol AudioSessionControlling: Sendable {
    func activateForRecording() throws
    func deactivate()
}

public struct AudioSessionController: AudioSessionControlling {
    public init() {}

    /// ロック画面の intent などでバックグラウンドから始めるとき、他の音を止める（mix しない）セッションは
    /// 有効にできない（560557684 = '!int' cannotInterruptOthers）。そのため他の音と混ぜられる設定にする。
    /// 録るのは内蔵マイクで変わらない。1回失敗したら少し待ってもう1回だけ試す。
    public func activateForRecording() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        do {
            try session.setActive(true)
        } catch {
            Thread.sleep(forTimeInterval: 0.3)
            try session.setActive(true)
        }
        #endif
    }

    public func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

public enum MicrophonePermission {
    /// マイクの許可を確認し、未確認なら尋ねる。
    public static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public static var isGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }
}
