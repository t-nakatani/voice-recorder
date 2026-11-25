// swift-tools-version: 6.0
// RecorderKit: UI に依存しない部品（プリミティブ）を1モジュールずつ分けたパッケージ。
// 依存の向きは「各部品 → RecorderCore（型と契約）」のみ。組み立ては RecorderRuntime だけが行う。
import PackageDescription

let package = Package(
    name: "RecorderKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .library(name: "SegmentStore", targets: ["SegmentStore"]),
        .library(name: "UploadQueue", targets: ["UploadQueue"]),
        .library(name: "Destinations", targets: ["Destinations"]),
        .library(name: "BackgroundTransport", targets: ["BackgroundTransport"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "RecordingControl", targets: ["RecordingControl"]),
        .library(name: "RecorderRuntime", targets: ["RecorderRuntime"]),
    ],
    targets: [
        // 型と契約（protocol）だけ。Foundation 以外に依存しない。
        .target(name: "RecorderCore"),
        // 区切りファイルと録音台帳をローカルに保存する。
        .target(name: "SegmentStore", dependencies: ["RecorderCore"]),
        // 宛先ごとの配送状態の台帳と、送信・再送のスケジューラ。
        .target(name: "UploadQueue", dependencies: ["RecorderCore"]),
        // 宛先の実装（Worker 発行の署名付きURL）と端末トークンの保管。
        .target(name: "Destinations", dependencies: ["RecorderCore"]),
        // バックグラウンド URLSession による実際の送信。
        .target(name: "BackgroundTransport", dependencies: ["RecorderCore"]),
        // AVAudioEngine で録音し、一定秒数ごとに独立した m4a に区切る。
        .target(name: "AudioCapture", dependencies: ["RecorderCore"]),
        // ロック画面・コントロールセンター・アクションボタン用の App Intents と Live Activity。
        // アプリ本体とウィジェット拡張の両方にリンクする。
        .target(name: "RecordingControl", dependencies: ["RecorderCore"]),
        // 上の部品を組み立てる唯一の場所。UI はここだけを見る。
        .target(
            name: "RecorderRuntime",
            dependencies: [
                "RecorderCore", "SegmentStore", "UploadQueue", "Destinations",
                "BackgroundTransport", "AudioCapture", "RecordingControl",
            ]
        ),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
        .testTarget(name: "SegmentStoreTests", dependencies: ["SegmentStore"]),
        .testTarget(name: "UploadQueueTests", dependencies: ["UploadQueue"]),
        .testTarget(name: "DestinationsTests", dependencies: ["Destinations"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
    ],
    swiftLanguageModes: [.v5]
)
