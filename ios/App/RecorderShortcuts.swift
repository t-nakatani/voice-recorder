import AppIntents

// アプリ本体だけにコンパイルする。ショートカットアプリとアクションボタンの一覧に出る。
struct RecorderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["\(.applicationName)で録音"],
                    shortTitle: "録音を開始", systemImageName: "mic.fill")
        AppShortcut(intent: OpenAndRecordIntent(), phrases: ["\(.applicationName)を開いて録音"],
                    shortTitle: "開いて録音", systemImageName: "mic.circle")
        AppShortcut(intent: StopRecordingIntent(), phrases: ["\(.applicationName)の録音を停止"],
                    shortTitle: "録音を停止", systemImageName: "stop.fill")
    }
}
