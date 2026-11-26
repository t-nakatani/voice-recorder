import os
import AudioCapture
import Foundation
import RecorderCore
import RecordingControl
import SegmentStore
import UploadQueue

/// 部品を組み立てて「録音する・保存する・送る」を1つにまとめたもの。UI はこれだけを見る。
/// ロック画面の intent からも RecordingCommandCenter 経由でここが呼ばれる。
@MainActor
public final class RecordingService: ObservableObject, RecordingCommandHandling {
    @Published public private(set) var activeRecording: Recording?
    @Published public private(set) var recordings: [Recording] = []
    @Published public private(set) var summaries: [RecordingID: DeliverySummary] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var isPaused = false
    /// 区切りごとの最大音量（dBFS）。無音で録れていないかを画面で見るため。録音ID → 区切り番号 → dBFS
    @Published public private(set) var segmentPeaks: [RecordingID: [Int: Double]] = [:]
    /// 音量の知らせを受ける録音（止めた直後に閉じた区切りの分も受けるため、次の録音を始めるまで残す）
    private var levelRecordingID: RecordingID?
    private let levels: SegmentLevelStore

    public let store: FileRecordingStore
    public let ledger: DeliveryLedger
    public let scheduler: UploadScheduler
    private let capture: AudioCapturing
    private let activity: RecordingActivityPresenting
    private let format: AudioFormat
    private let retention: RetentionPolicy
    private let clock: Clock
    private let pendingStart: PendingStartFlag

    private var listenTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var launched = false

    public init(store: FileRecordingStore, ledger: DeliveryLedger, scheduler: UploadScheduler, capture: AudioCapturing,
                activity: RecordingActivityPresenting, format: AudioFormat = .aacMono64k,
                retention: RetentionPolicy = .keepForever, pendingStart: PendingStartFlag, clock: Clock = SystemClock(),
                levels: SegmentLevelStore = SegmentLevelStore(suiteName: nil)) {
        self.levels = levels
        self.segmentPeaks = levels.load()
        self.store = store
        self.ledger = ledger
        self.scheduler = scheduler
        self.capture = capture
        self.activity = activity
        self.format = format
        self.retention = retention
        self.pendingStart = pendingStart
        self.clock = clock
    }

    public var isRecording: Bool { activeRecording != nil }

    static let logger = Logger(subsystem: "com.uniedge-labs.voicerecorder", category: "recording")

    // MARK: 起動

    /// アプリ起動時に1回呼ぶ。落ちて残った録音の復旧 → 送信状態の突き合わせ → 未送信の送信。
    public func launch() async {
        guard !launched else { return }
        launched = true
        // 録音していないのに残っている Live Activity（落ちた・止めたのに消えなかった等）を消す
        if activeRecording == nil { await activity.endAll() }
        do {
            try store.recoverUnclosedRecordings(except: activeRecording?.id, probeDuration: AudioFileProbe.duration(of:))
        } catch {
            lastError = "復旧に失敗: \(error)"
        }
        let scheduler = self.scheduler
        listenTask = Task.detached { await scheduler.listen() }
        await scheduler.observe { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        await scheduler.reconcile()
        await scheduler.pump()
        await sweepRetention()
        await refresh()
    }

    /// アプリが前面に来たとき。方式Bの「開いたら録音」の印があれば始める。ついでに送信を促す。
    public func didBecomeActive() async {
        if pendingStart.consume(now: clock.now()), !isRecording {
            try? await startRecording(trigger: .controlOpenApp)
        }
        await scheduler.pump()
        await refresh()
    }

    /// ネットワークが戻った・バックグラウンド更新で起こされた、など。
    public func kickUploads() async {
        await scheduler.pump()
        await refresh()
    }

    // MARK: RecordingCommandHandling

    public func startRecording(trigger: RecordingTrigger) async throws {
        _ = pendingStart.consume(now: clock.now())
        guard activeRecording == nil else {
            Self.logger.notice("start ignored: already recording (trigger=\(trigger.rawValue, privacy: .public))")
            return
        }
        Self.logger.notice("start trigger=\(trigger.rawValue, privacy: .public)")
        let id = RecordingID.make(at: clock.now())
        let recording = try store.createRecording(id: id, startedAt: clock.now(), format: format)
        activeRecording = recording
        isPaused = false
        levelRecordingID = id

        // AudioRecordingIntent の決まり: 録音を始めたら Live Activity を出す
        do {
            try activity.begin(recordingID: id.rawValue, state: .init(startedAt: recording.startedAt))
        } catch {
            lastError = "Live Activity を出せませんでした: \(error)"
            Self.logger.error("live activity failed: \(String(describing: error), privacy: .public)")
        }

        let store = self.store
        do {
            try capture.start(firstIndex: 0, segmentURL: { index in
                try store.pendingSegmentURL(recordingID: id, index: index)
            }, onEvent: { [weak self] event in
                // 台帳への登録はこのスレッドで即座に行う（停止時に manifest より先に載るように）
                if case .segmentFinished(let index, let offset, let duration) = event {
                    do {
                        try store.commitSegment(recordingID: id, index: index, startOffset: offset, duration: duration)
                    } catch {
                        // ファイルは書きかけの名前（000001.partial.m4a）のまま残る。閉じる前の commitLeftoverSegments か、起動時の復旧で拾い直す
                        let message = "区切り \(index) を台帳に載せられませんでした: \(error)"
                        Task { @MainActor in self?.lastError = message }
                    }
                }
                Task { @MainActor in await self?.handle(event, recordingID: id) }
            })
        } catch {
            activeRecording = nil
            try? store.closeRecording(id: id, endedAt: clock.now(), status: .interrupted)
            await activity.end(recordingID: id.rawValue, state: nil)
            lastError = "録音を始められませんでした: \(error)"
            Self.logger.error("capture start failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        await refresh()
    }

    public func stopRecording() async throws {
        guard let recording = activeRecording else {
            Self.logger.notice("stop ignored: not recording")
            return
        }
        Self.logger.notice("stop recording=\(recording.id.rawValue, privacy: .public)")
        capture.stop() // 書きかけの区切りを閉じて台帳に載せてから戻る
        activeRecording = nil
        isPaused = false
        try await finalize(recording.id, status: .finished)
    }

    /// 録音を閉じる。台帳に載り損ねた区切りを先に拾い、拾えなければ閉じずに残す（次の起動時の復旧に任せる）。
    /// 閉じた録音は復旧の対象にならないので、区切りが欠けたまま manifest を作らないようにする。
    private func finalize(_ id: RecordingID, status: RecordingStatus) async throws {
        do {
            try store.commitLeftoverSegments(recordingID: id, probeDuration: AudioFileProbe.duration(of:))
            let closed = try store.closeRecording(id: id, endedAt: clock.now(), status: status)
            await activity.end(recordingID: id.rawValue, state: activityState(for: closed, endedAt: closed.endedAt ?? clock.now()))
        } catch {
            lastError = "録音を閉じられませんでした（ファイルは iPhone に残っています。次の起動時に復旧します）: \(error)"
            await activity.end(recordingID: id.rawValue, state: nil)
            await scheduler.pump()
            await refresh()
            throw error
        }
        await scheduler.pump()
        await refresh()
    }

    // MARK: 録音イベント

    private func handle(_ event: CaptureEvent, recordingID: RecordingID) async {
        switch event {
        case .segmentFinished:
            await scheduler.pump()
        case .interrupted:
            isPaused = true
        case .resumed:
            isPaused = false
        case .failed(let message):
            lastError = message
            if activeRecording?.id == recordingID {
                // 録音部品を止めて状態を戻す（止めないと次の録音で start が何もせずに戻る）
                capture.stop()
                activeRecording = nil
                isPaused = false
                try? await finalize(recordingID, status: .interrupted)
                lastError = message
            }
        }
        await refresh()
    }

    // MARK: 表示用

    public func refresh() async {
        let all = (try? store.allRecordings()) ?? []
        var map: [RecordingID: DeliverySummary] = [:]
        for recording in all { map[recording.id] = await scheduler.summary(for: recording) }
        recordings = all
        summaries = map
        if let active = activeRecording, let latest = all.first(where: { $0.id == active.id }) {
            activeRecording = latest
            await activity.update(activityState(for: latest))
        }
        scheduleRetryTimer()
    }

    /// 録音部品から区切りの最大音量を受け取る（AppEnvironment がつなぐ）
    public func noteSegmentLevel(index: Int, peakDBFS: Double) {
        guard let id = levelRecordingID else { return }
        segmentPeaks[id, default: [:]][index] = peakDBFS
        levels.save(segmentPeaks)
    }

    private func activityState(for recording: Recording, endedAt: Date? = nil) -> RecordingActivityAttributes.ContentState {
        let primary = summaries[recording.id]?.perDestination.first
        return .init(startedAt: recording.startedAt, isPaused: isPaused,
                     uploadedSegments: min(primary?.delivered ?? 0, recording.segments.count),
                     totalSegments: recording.segments.count, endedAt: endedAt)
    }

    /// 次の再送時刻にタイマーを張る（アプリが動いている間だけ。止まっている間は起動時・ネット回復時に拾う）。
    private func scheduleRetryTimer() {
        retryTask?.cancel()
        let scheduler = self.scheduler
        retryTask = Task { [weak self] in
            guard let next = await scheduler.nextRetryDate() else { return }
            let wait = max(1, next.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.kickUploads()
        }
    }

    private func sweepRetention() async {
        let now = clock.now()
        for recording in (try? store.allRecordings()) ?? [] where recording.id != activeRecording?.id {
            let delivered = await scheduler.isFullyDelivered(recording)
            if retention.mayDelete(recording, fullyDelivered: delivered, now: now) {
                try? store.deleteRecording(id: recording.id)
                try? ledger.removeAll(for: recording.id)
            }
        }
    }
}
