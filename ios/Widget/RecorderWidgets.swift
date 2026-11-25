import ActivityKit
import AppIntents
import RecordingControl
import SwiftUI
import WidgetKit

@main
struct RecorderWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordControl()
        OpenAndRecordControl()
        RecordingLiveActivity()
    }
}

/// 方式A: ロック画面・コントロールセンター・アクションボタンに置く「録音」ボタン（ロック解除なし）。
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.uniedge-labs.voicerecorder.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("録音", systemImage: "mic.fill")
            }
        }
        .displayName("録音")
        .description("ロックを解除せずに録音を始めます。")
    }
}

/// 方式B: アプリを開いて録音（Face ID が挟まるが確実に動く）。
struct OpenAndRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.uniedge-labs.voicerecorder.open-and-record") {
            ControlWidgetButton(action: OpenAndRecordIntent()) {
                Label("開いて録音", systemImage: "mic.circle")
            }
        }
        .displayName("開いて録音")
        .description("アプリを開き、すぐに録音を始めます。")
    }
}

/// 録音中にロック画面とダイナミックアイランドに出す表示（仮デザイン）。
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text(context.state.isPaused ? "一時停止中" : "録音中").font(.headline)
                    Text(context.state.startedAt, style: .timer).monospacedDigit()
                    Text("送信 \(context.state.uploadedSegments)/\(context.state.totalSegments)").font(.caption)
                }
                Spacer()
                Button(intent: StopRecordingIntent()) {
                    Label("停止", systemImage: "stop.fill")
                }
                .tint(.red)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.startedAt, style: .timer).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopRecordingIntent()) { Image(systemName: "stop.fill") }
                }
            } compactLeading: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer).monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
    }
}
