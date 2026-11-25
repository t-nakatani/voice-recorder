import Foundation
import RecorderCore

/// 送信と再送の司令塔。
///
/// やること:
/// - 台帳（RecordingStore）と配送台帳（DeliveryLedger）を見て、まだ届いていない UploadJob を探す
/// - 宛先に署名付きURLを用意させ、送信部品（UploadTransport）に渡す
/// - 送信結果を受けて配送台帳を更新し、失敗したら RetryPolicy の間隔で送り直す
///
/// 決まりごと:
/// - manifest は、その宛先に全区切りが届いてから送る（サーバー側で「そろった」と判断できるように）
/// - 同じジョブを何度送ってもよい（キーが固定なので上書きになるだけ）
/// - 諦めない。失敗は間隔を伸ばして送り直す
public actor UploadScheduler {
    public struct Configuration: Sendable {
        /// 同時に OS へ頼んでおく送信の上限
        public var maxConcurrent: Int
        /// これより長く inFlight のままなら、OS が取りこぼしたとみなして送り直す
        public var inFlightTimeout: TimeInterval
        public var retry: RetryPolicy

        public init(maxConcurrent: Int = 4, inFlightTimeout: TimeInterval = 6 * 60 * 60, retry: RetryPolicy = RetryPolicy()) {
            self.maxConcurrent = maxConcurrent
            self.inFlightTimeout = inFlightTimeout
            self.retry = retry
        }
    }

    private let store: RecordingStore
    private let ledger: DeliveryLedger
    private var destinations: [DestinationID: Destination]
    private var destinationOrder: [DestinationID]
    private let transport: UploadTransport
    private let configuration: Configuration
    private let clock: Clock
    private let random: @Sendable () -> Double

    private var isPumping = false
    private var pumpRequested = false
    private var listening = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(store: RecordingStore, ledger: DeliveryLedger, destinations: [Destination], transport: UploadTransport,
                configuration: Configuration = Configuration(), clock: Clock = SystemClock(),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.store = store
        self.ledger = ledger
        self.destinations = Dictionary(destinations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.destinationOrder = destinations.map(\.id)
        self.transport = transport
        self.configuration = configuration
        self.clock = clock
        self.random = random
    }

    // MARK: 公開API

    /// 送信結果の受信を始める。アプリ起動時に1回呼ぶ（戻らない）。
    public func listen() async {
        guard !listening else { return }
        listening = true
        for await event in transport.events {
            await handle(event)
        }
    }

    /// 宛先の入れ替え（設定画面から）。既存の配送状態は宛先IDで引き継がれる。
    public func replaceDestinations(_ list: [Destination]) {
        destinations = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        destinationOrder = list.map(\.id)
    }

    /// 起動時に呼ぶ。台帳で inFlight なのに OS 側に送信がないものを pending に戻す。
    public func reconcile() async {
        let active = await transport.activeJobTokens()
        for recording in (try? store.allRecordings()) ?? [] {
            for (job, state) in ledger.states(for: recording.id) {
                if case .inFlight = state, !active.contains(job.token) {
                    try? ledger.set(.pending, for: job)
                }
            }
        }
    }

    /// 送れるものを送る。区切りが増えた・録音が閉じた・ネットが戻った・起動した、などのたびに呼んでよい。
    public func pump() async {
        if isPumping { pumpRequested = true; return }
        isPumping = true
        defer { isPumping = false }
        repeat {
            pumpRequested = false
            await pumpOnce()
        } while pumpRequested
    }

    /// 次に再送予定がある最も早い時刻（タイマーを張るのに使う）。
    public func nextRetryDate() -> Date? {
        var earliest: Date?
        for recording in (try? store.allRecordings()) ?? [] {
            for (_, state) in ledger.states(for: recording.id) {
                if case .failed(_, _, let next) = state { earliest = min(earliest ?? next, next) }
            }
        }
        return earliest
    }

    public func summary(for recording: Recording) -> DeliverySummary {
        DeliverySummary(recording: recording, destinations: destinationOrder, ledger: ledger)
    }

    public func isFullyDelivered(_ recording: Recording) -> Bool {
        summary(for: recording).isComplete
    }

    /// 状態が変わったら呼ばれる（UI の更新用）。
    @discardableResult
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    // MARK: 内部

    func plannedJobs() -> [UploadJob] {
        let now = clock.now()
        var jobs: [UploadJob] = []
        let recordings = ((try? store.allRecordings()) ?? []).sorted { $0.id < $1.id } // 古い録音から
        for recording in recordings {
            let states = ledger.states(for: recording.id)
            for destination in destinationOrder {
                var allSegmentsDelivered = true
                for segment in recording.segments {
                    let job = UploadJob(recordingID: recording.id, item: .segment(segment.index), destination: destination)
                    let state = states[job] ?? .pending
                    if !state.isDelivered { allSegmentsDelivered = false }
                    if isDue(state, now: now) { jobs.append(job) }
                }
                if recording.isClosed && allSegmentsDelivered {
                    let job = UploadJob(recordingID: recording.id, item: .manifest, destination: destination)
                    if isDue(states[job] ?? .pending, now: now) { jobs.append(job) }
                }
            }
        }
        return jobs
    }

    func inFlightCount() -> Int {
        let now = clock.now()
        var count = 0
        for recording in (try? store.allRecordings()) ?? [] {
            for (_, state) in ledger.states(for: recording.id) {
                if case .inFlight(let startedAt, _) = state,
                   now.timeIntervalSince(startedAt) < configuration.inFlightTimeout { count += 1 }
            }
        }
        return count
    }

    private func isDue(_ state: DeliveryState, now: Date) -> Bool {
        switch state {
        case .pending: return true
        case .delivered: return false
        case .failed(_, _, let next): return next <= now
        case .inFlight(let startedAt, _): return now.timeIntervalSince(startedAt) >= configuration.inFlightTimeout
        }
    }

    private func pumpOnce() async {
        var budget = configuration.maxConcurrent - inFlightCount()
        guard budget > 0 else { return }
        for job in plannedJobs() {
            guard budget > 0 else { break }
            if await start(job) { budget -= 1 }
        }
        notify()
    }

    /// 送信を1つ始める。OS に渡せたら true。
    private func start(_ job: UploadJob) async -> Bool {
        guard let destination = destinations[job.destination] else { return false }
        let attempt = ledger.state(of: job).attempts + 1
        do {
            guard let recording = try store.recording(id: job.recordingID) else { return false }
            let fileURL = try store.fileURL(for: job.item, of: job.recordingID)
            let descriptor = try makeDescriptor(job.item, recording: recording, fileURL: fileURL)
            try ledger.set(.inFlight(startedAt: clock.now(), attempt: attempt), for: job)
            let prepared = try await destination.prepareUpload(descriptor)
            try await transport.startUpload(prepared, fileURL: fileURL, jobToken: job.token)
            return true
        } catch {
            markFailed(job, attempts: attempt, message: String(describing: error))
            return false
        }
    }

    private func makeDescriptor(_ item: UploadItem, recording: Recording, fileURL: URL) throws -> UploadDescriptor {
        let key = ObjectKeys.key(for: item, of: recording)
        switch item {
        case .segment(let index):
            guard let segment = recording.segments.first(where: { $0.index == index }) else {
                throw SchedulerError.segmentMissing(index)
            }
            return UploadDescriptor(key: key, contentType: recording.format.contentType,
                                    byteCount: segment.byteCount, sha256Hex: segment.sha256)
        case .manifest:
            let (hex, bytes) = try FileHashing.sha256(of: fileURL)
            return UploadDescriptor(key: key, contentType: "application/json", byteCount: bytes, sha256Hex: hex)
        }
    }

    func handle(_ event: TransportEvent) async {
        switch event {
        case .completed(let token, let status):
            guard let job = UploadJob(token: token) else { return }
            let attempts = max(1, ledger.state(of: job).attempts)
            if (200..<300).contains(status) {
                try? ledger.set(.delivered(at: clock.now()), for: job)
            } else if status == 403 || status == 401 {
                // 署名付きURLの期限切れが多い。すぐに URL を取り直して送る
                try? ledger.set(.failed(attempts: attempts, lastError: "HTTP \(status)", nextAttemptAt: clock.now()), for: job)
            } else {
                markFailed(job, attempts: attempts, message: "HTTP \(status)")
            }
        case .failed(let token, let message):
            guard let job = UploadJob(token: token) else { return }
            markFailed(job, attempts: max(1, ledger.state(of: job).attempts), message: message)
        }
        await pump()
    }

    private func markFailed(_ job: UploadJob, attempts: Int, message: String) {
        let delay = configuration.retry.delay(afterAttempts: attempts, random: random())
        try? ledger.set(.failed(attempts: attempts, lastError: message,
                                nextAttemptAt: clock.now().addingTimeInterval(delay)), for: job)
    }

    private func notify() {
        for callback in observers.values { callback() }
    }
}

public enum SchedulerError: Error, Equatable {
    case segmentMissing(Int)
}

/// UI 向けの集計。宛先ごとに「何個中何個届いたか」。
public struct DeliverySummary: Sendable, Equatable {
    public struct PerDestination: Sendable, Equatable {
        public var destination: DestinationID
        public var delivered: Int
        public var total: Int
        public var failing: Int
        public var lastError: String?
        public var isComplete: Bool { delivered == total }
    }

    public var perDestination: [PerDestination]
    public var isComplete: Bool { !perDestination.isEmpty && perDestination.allSatisfy(\.isComplete) }

    public init(recording: Recording, destinations: [DestinationID], ledger: DeliveryLedger) {
        let states = ledger.states(for: recording.id)
        var items: [UploadItem] = recording.segments.map { .segment($0.index) }
        if recording.isClosed { items.append(.manifest) }
        perDestination = destinations.map { destination in
            var delivered = 0, failing = 0
            var lastError: String?
            for item in items {
                switch states[UploadJob(recordingID: recording.id, item: item, destination: destination)] ?? .pending {
                case .delivered: delivered += 1
                case .failed(_, let message, _): failing += 1; lastError = message
                default: break
                }
            }
            // 録音中は manifest がまだないので、閉じるまでは完了扱いにしない
            let total = recording.isClosed ? items.count : items.count + 1
            return PerDestination(destination: destination, delivered: delivered, total: total,
                                  failing: failing, lastError: lastError)
        }
    }
}
