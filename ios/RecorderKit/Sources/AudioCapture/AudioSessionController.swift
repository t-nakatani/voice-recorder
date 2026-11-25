@preconcurrency import AVFoundation
import Foundation

/// AVAudioSession の設定。差し替えられるように protocol にしておく。
public protocol AudioSessionControlling: Sendable {
    func activateForRecording() throws
    func deactivate()
}

public struct AudioSessionController: AudioSessionControlling {
    public init() {}

    public func activateForRecording() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
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
