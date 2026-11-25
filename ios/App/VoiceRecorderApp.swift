import AudioCapture
import RecorderRuntime
import RecordingControl
import SwiftUI
import UIKit

// UI は捨てる前提の仮のもの。部品は RecorderKit（Sources/）にあり、ここは組み立てと表示だけ。

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 画面を出さずに起こされる（送信完了など）こともあるので、App の init で入れる
    @MainActor static var built: AppEnvironment.Built?

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // 送信完了でアプリが起こされたとき。URLSession のイベントを全部受け取ったら completionHandler を呼ぶ
        MainActor.assumeIsolated {
            AppDelegate.built?.transport.setBackgroundCompletionHandler(completionHandler)
        }
    }
}

@main
struct VoiceRecorderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var service: RecordingService
    private let built: AppEnvironment.Built
    private let network = NetworkMonitor()

    init() {
        // intent で起こされたときもここが走るので、ここで handler を登録する（AppEnvironment.make の中）
        let built = try! AppEnvironment.make(.init(appGroup: AppConfig.appGroup, keychainService: AppConfig.keychainService))
        self.built = built
        AppDelegate.built = built
        _service = StateObject(wrappedValue: built.service)
        let service = built.service
        network.start { Task { @MainActor in await service.kickUploads() } }
        // 停止の intent がウィジェット拡張で動いたときは、Darwin 通知で届く
        CrossProcessCommand.stop.observe {
            Task { @MainActor in try? await service.stopRecording() }
        }
        Task { @MainActor in await service.launch() }
    }

    var body: some Scene {
        WindowGroup {
            DebugRootView(built: built)
                .environmentObject(service)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    _ = await MicrophonePermission.request()
                    await service.didBecomeActive()
                }
            }
        }
    }
}

enum AppConfig {
    /// project.yml と Shared/RecordingIntents.swift の SharedConstants.appGroup と揃える
    static let appGroup = "group.com.uniedge-labs.voicerecorder"
    static let keychainService = "com.uniedge-labs.voicerecorder.tokens"
}
