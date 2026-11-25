import AppIntents
import Foundation
import RecordingControl

// アプリ本体とウィジェット拡張の両方にコンパイルする（project.yml の sources を参照）。
// 実際の録音処理はアプリ本体の RecordingCommandCenter に登録された handler が行う。

/// 方式A: ロック解除なしで録音を始める。
/// Apple の決まり: AudioRecordingIntent で録音するときは、開始と同時に Live Activity を出し続ける
/// （handler 側の RecordingService.start が LiveActivityController.begin を呼ぶ）。
/// ここがロック中の実機で動くかどうかが最初のスパイクの確認項目。
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "録音を開始"
    static let description = IntentDescription("ロックを解除せずに録音を始めます。")

    func perform() async throws -> some IntentResult {
        try await RecordingCommandCenter.shared.requireHandler().startRecording(trigger: .controlWithoutUnlock)
        return .result()
    }
}

/// 方式B: アプリを開いて（Face ID）、開いた瞬間に録音を始める。方式Aが動かない場合の正式な経路。
struct OpenAndRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "アプリを開いて録音"
    static let description = IntentDescription("アプリを開き、すぐに録音を始めます。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingStartFlag(suiteName: SharedConstants.appGroup).raise()
        if let handler = RecordingCommandCenter.shared.handler {
            // アプリのプロセスで動いていれば直接始める（印は handler 側で消す）
            try await handler.startRecording(trigger: .controlOpenApp)
        }
        return .result()
    }
}

/// 録音を止める。Live Activity のボタンとショートカットから使う。
/// LiveActivityIntent にするとアプリのプロセスで実行される。
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "録音を停止"
    static let description = IntentDescription("録音を止めて保存します。")

    func perform() async throws -> some IntentResult {
        try await RecordingCommandCenter.shared.requireHandler().stopRecording()
        return .result()
    }
}

enum SharedConstants {
    /// project.yml の App Group と揃える
    static let appGroup = "group.com.uniedge-labs.voicerecorder"
}
