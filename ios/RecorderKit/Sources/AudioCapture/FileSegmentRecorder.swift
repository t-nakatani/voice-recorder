@preconcurrency import AVFoundation
import Foundation
import RecorderCore

/// AVAudioRecorder でマイクを録り、segmentDuration 秒ごとに新しい m4a（AAC）へ切り替える。
///
/// ロック画面のコントロールから（アプリが裏にいるまま）始めるときの本命。
/// 実機では AVAudioEngine の開始がバックグラウンドで断られた（kAUStartIO が 2003329396 'what'）。
/// ロック中に録れている例（huske、jarvis-ios、avibe）はどれも AVAudioRecorder で録っている。
///
/// - 区切りの切り替えは「次のレコーダーを始めてから前のを止める」。隙間は出ず、重なりは数十ミリ秒
/// - 次のレコーダーを始められなかったときは、今のを続けて次の見回りでもう一度試す
/// - 電話などの割り込みで止まったら区切りを閉じ、割り込みが終われば新しい区切りから再開する
public final class FileSegmentRecorder: AudioCapturing, @unchecked Sendable {
    public typealias Settings = SegmentedAudioRecorder.Settings

    private struct Active {
        var recorder: AVAudioRecorder
        var index: Int
        var startOffset: TimeInterval
        var peakDB: Float = -.infinity
    }

    private let settings: Settings
    private let session: AudioSessionControlling
    /// AVAudioRecorder の操作はすべてこのキューで行う
    private let queue = DispatchQueue(label: "voicerecorder.file-segment-recorder")
    private var timer: DispatchSourceTimer?
    private var active: Active?
    private var nextIndex = 0
    private var nextOffset: TimeInterval = 0
    private var segmentURL: ((Int) throws -> URL)?
    private var onEvent: (@Sendable (CaptureEvent) -> Void)?
    private var running = false
    private var paused = false
    private var observers: [NSObjectProtocol] = []
    public var onSegmentLevel: (@Sendable (_ index: Int, _ peakDBFS: Double) -> Void)?
    /// 約1秒ごとに、その間の最大音量（dBFS。無音は -inf）を知らせる。無音が続いたら自動で止めるため
    public var onLevelSample: (@Sendable (_ peakDBFS: Double) -> Void)?
    private var samplePeakDB: Float = -.infinity
    private var sampleTicks = 0

    public init(settings: Settings = Settings(), session: AudioSessionControlling = AudioSessionController()) {
        self.settings = settings
        self.session = session
    }

    public var isRunning: Bool { queue.sync { running } }

    /// 失敗してもセッションは有効のまま返す（同じセッションのまま AVAudioEngine で試し直せるように）。
    public func start(firstIndex: Int, segmentURL: @escaping (Int) throws -> URL,
                      onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        try queue.sync {
            guard !running else { return }
            try session.activateForRecording()
            self.segmentURL = segmentURL
            self.onEvent = onEvent
            nextIndex = firstIndex
            nextOffset = 0
            active = try makeRecorderLocked()
            running = true
            paused = false
            startTimerLocked()
        }
        observeSystemNotifications()
    }

    public func stop() {
        let closed: (Int, TimeInterval, TimeInterval)? = queue.sync {
            guard running else { return nil }
            running = false
            stopTimerLocked()
            return closeActiveLocked()
        }
        removeObservers()
        if let closed { onEvent?(.segmentFinished(index: closed.0, startOffset: closed.1, duration: closed.2)) }
        session.deactivate()
    }

    // MARK: レコーダー（queue の上で呼ぶ）

    private func makeRecorderLocked() throws -> Active {
        guard let segmentURL else { throw CaptureError.noInput }
        let index = nextIndex
        let url = try segmentURL(index)
        let recorderSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: settings.bitRate,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: recorderSettings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderStartError.recordRefused
        }
        nextIndex = index + 1
        return Active(recorder: recorder, index: index, startOffset: nextOffset)
    }

    /// 今の区切りを閉じて (番号, 開始位置, 長さ) を返す。
    private func closeActiveLocked() -> (Int, TimeInterval, TimeInterval)? {
        guard var current = active else { return nil }
        active = nil
        sampleLevel(&current)
        let duration = current.recorder.currentTime
        current.recorder.stop() // ここで m4a が書き終わる
        nextOffset = current.startOffset + duration
        onSegmentLevel?(current.index, current.peakDB.isFinite ? Double(current.peakDB) : -.infinity)
        return (current.index, current.startOffset, duration)
    }

    private func sampleLevel(_ current: inout Active) {
        current.recorder.updateMeters()
        let peak = current.recorder.peakPower(forChannel: 0)
        // 完全な無音は -160 dB と出る
        if peak > -160 {
            current.peakDB = max(current.peakDB, peak)
            samplePeakDB = max(samplePeakDB, peak)
        }
    }

    private func startTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    /// 0.25 秒ごと: 音量を測り、区切りの長さに達したら次のファイルへ切り替える。
    private func tick() {
        guard running, !paused, var current = active else { return }
        sampleLevel(&current)
        active = current
        sampleTicks += 1
        if sampleTicks >= 4 {
            onLevelSample?(samplePeakDB.isFinite ? Double(samplePeakDB) : -.infinity)
            sampleTicks = 0
            samplePeakDB = -.infinity
        }
        guard current.recorder.currentTime >= settings.segmentDuration else { return }
        let next: Active
        do {
            next = try makeRecorderLocked()
        } catch {
            return // 今の区切りを続け、次の見回りでまた試す
        }
        // 次が録り始めてから前を止める
        let closed = closeActiveLocked()
        var started = next
        started.startOffset = nextOffset
        active = started
        if let closed { onEvent?(.segmentFinished(index: closed.0, startOffset: closed.1, duration: closed.2)) }
    }

    // MARK: 割り込み

    private func observeSystemNotifications() {
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began: self?.pause()
            case .ended: self?.resume() // shouldResume が無くても、録音アプリなので再開を試みる
            @unknown default: break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: nil) { [weak self] _ in
            self?.pause()
            self?.resume()
        })
        #endif
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func pause() {
        let closed: (Int, TimeInterval, TimeInterval)? = queue.sync {
            guard running, !paused else { return nil }
            paused = true
            return closeActiveLocked()
        }
        if let closed { onEvent?(.segmentFinished(index: closed.0, startOffset: closed.1, duration: closed.2)) }
        onEvent?(.interrupted)
    }

    private func resume() {
        let result: Result<Void, Error>? = queue.sync {
            guard running, paused else { return nil }
            do {
                try session.activateForRecording()
                active = try makeRecorderLocked()
                paused = false
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success: onEvent?(.resumed)
        case .failure(let error): onEvent?(.failed(message: "割り込み後に再開できませんでした: \(error)"))
        case nil: break
        }
    }
}

public enum RecorderStartError: Error, CustomStringConvertible {
    /// AVAudioRecorder.record() が false を返した
    case recordRefused
    /// どの方法でも始められなかった
    case allFailed([String])

    public var description: String {
        switch self {
        case .recordRefused: "AVAudioRecorder.record() が false を返した"
        case .allFailed(let tries): tries.joined(separator: " / ")
        }
    }
}

/// 先に AVAudioRecorder で始め、断られたら同じセッションのまま AVAudioEngine で試す（jarvis-ios #41 と同じ順）。
/// 両方だめならセッションを閉じて、両方の理由をまとめて投げる。
public final class FallbackAudioCapture: AudioCapturing, @unchecked Sendable {
    private let primary: FileSegmentRecorder
    private let fallback: SegmentedAudioRecorder
    private let session: AudioSessionControlling
    private let lock = NSLock()
    private var current: AudioCapturing?
    /// 直近の開始で使った方法（"recorder" / "engine"）
    public private(set) var lastMethod: String?

    public init(settings: SegmentedAudioRecorder.Settings = .init(),
                session: AudioSessionControlling = AudioSessionController()) {
        self.session = session
        primary = FileSegmentRecorder(settings: settings, session: session)
        fallback = SegmentedAudioRecorder(settings: settings, session: session)
    }

    public var onSegmentLevel: (@Sendable (_ index: Int, _ peakDBFS: Double) -> Void)? {
        get { primary.onSegmentLevel }
        set { primary.onSegmentLevel = newValue; fallback.onSegmentLevel = newValue }
    }

    public var onLevelSample: (@Sendable (_ peakDBFS: Double) -> Void)? {
        get { primary.onLevelSample }
        set { primary.onLevelSample = newValue; fallback.onLevelSample = newValue }
    }

    public var isRunning: Bool { (lock.withLock { current })?.isRunning ?? false }

    public func start(firstIndex: Int, segmentURL: @escaping (Int) throws -> URL,
                      onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        var tries: [String] = []
        do {
            try primary.start(firstIndex: firstIndex, segmentURL: segmentURL, onEvent: onEvent)
            lock.withLock { current = primary; lastMethod = "recorder" }
            return
        } catch {
            tries.append("recorder: \(Self.describe(error))")
        }
        do {
            try fallback.start(firstIndex: firstIndex, segmentURL: segmentURL, onEvent: onEvent)
            lock.withLock { current = fallback; lastMethod = "engine" }
            return
        } catch {
            tries.append("engine: \(Self.describe(error))")
        }
        session.deactivate()
        throw RecorderStartError.allFailed(tries)
    }

    public func stop() {
        let running = lock.withLock { () -> AudioCapturing? in
            defer { current = nil }
            return current
        }
        running?.stop()
    }

    /// NSError は domain と code が分かれば足りる
    static func describe(_ error: Error) -> String {
        if let error = error as? RecorderStartError { return error.description }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)\(fourCC(ns.code).map { " '\($0)'" } ?? "")"
    }

    static func fourCC(_ code: Int) -> String? {
        guard code > 0x1F_FF_FF_FF, code <= 0x7F_FF_FF_FF else { return nil }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}
