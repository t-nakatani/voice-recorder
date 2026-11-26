import AppIntents
import Foundation
import RecordingControl

// アプリ本体とウィジェット拡張の両方にコンパイルする（project.yml の sources を参照）。
// 実際の録音処理はアプリ本体の RecordingCommandCenter に登録された handler が行う。
// どのプロセスで動いたかと結果は IntentDiagnostics に残し、アプリの画面の「intent の記録」で見られる。

/// 方式A: ロック解除なしで録音を始める。
/// Apple の決まり: AudioRecordingIntent で録音するときは、開始と同時に Live Activity を出し続ける
/// （handler 側の RecordingService.start が LiveActivityController.begin を呼ぶ）。
/// ここがロック中の実機で動くかどうかが最初のスパイクの確認項目。
///
/// AudioRecordingIntent だけだと、コントロールから押したときにウィジェット拡張のプロセスで動き、
/// 録音するアプリ本体に届かない（実機で確認: Live Activity が出ず何も起きない）。
/// LiveActivityIntent も付けると、システムがアプリ本体をバックグラウンドで起こしてそのプロセスで動かす。
/// 参考: 同じ症状と直し方が jkrumm/iris#58、apandji/asthma-logger#57 などにある。
struct StartRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "録音を開始"
    static let description = IntentDescription("ロックを解除せずに録音を始めます。")
    /// ロック中でも動かす（既定だとロック解除を求められることがある）
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        try await IntentRun.perform("StartRecordingIntent") { handler in
            try await handler.startRecording(trigger: .controlWithoutUnlock)
        }
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
        let handler = RecordingCommandCenter.shared.handler
        var outcome = "ok（アプリが前面に来たら印を見て始める）"
        if let handler {
            // アプリのプロセスで動いていれば直接始める（印は handler 側で消す）
            do {
                outcome = "ok（\(try await handler.startRecording(trigger: .controlOpenApp))）"
            } catch {
                outcome = "失敗: \(error)"
                IntentRun.record("OpenAndRecordIntent", handler: true, outcome: outcome)
                throw error
            }
        }
        IntentRun.record("OpenAndRecordIntent", handler: handler != nil, outcome: outcome)
        return .result()
    }
}

/// 録音を止める。Live Activity のボタンとショートカットから使う。
/// LiveActivityIntent はアプリのプロセスで実行されるはずだが、ウィジェット拡張で動いた場合は
/// Darwin 通知で録音中のアプリ本体へ「止めて」を伝える。
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "録音を停止"
    static let description = IntentDescription("録音を止めて保存します。")
    /// ロック画面の Live Activity から止められるようにする
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult {
        if let handler = RecordingCommandCenter.shared.handler {
            do {
                try await handler.stopRecording()
                IntentRun.record("StopRecordingIntent", handler: true, outcome: "ok")
            } catch {
                IntentRun.record("StopRecordingIntent", handler: true, outcome: "失敗: \(error)")
                throw error
            }
        } else {
            CrossProcessCommand.stop.post()
            IntentRun.record("StopRecordingIntent", handler: false, outcome: "アプリ本体へ停止を通知した")
        }
        return .result()
    }
}

enum IntentRun {
    static func record(_ intent: String, handler: Bool, outcome: String) {
        IntentDiagnostics(suiteName: SharedConstants.appGroup).record(.init(
            at: Date(), intent: intent, process: IntentDiagnostics.currentProcess,
            handlerAvailable: handler, outcome: outcome))
    }

    /// handler を取り出して実行し、結果を記録する。handler が無ければ記録してから失敗を投げる。
    static func perform(_ intent: String,
                        _ body: (RecordingCommandHandling) async throws -> String?) async throws {
        guard let handler = RecordingCommandCenter.shared.handler else {
            record(intent, handler: false, outcome: "失敗: handler なし（アプリ本体以外のプロセスで実行された）")
            throw RecordingCommandError.handlerUnavailable
        }
        do {
            let note = try await body(handler)
            record(intent, handler: true, outcome: note.map { "ok（\($0)）" } ?? "ok")
        } catch {
            record(intent, handler: true, outcome: "失敗: \(error)")
            throw error
        }
    }
}

enum SharedConstants {
    /// project.yml の App Group と揃える
    static let appGroup = "group.com.uniedge-labs.voicerecorder"
}
