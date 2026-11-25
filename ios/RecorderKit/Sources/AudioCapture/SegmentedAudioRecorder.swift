@preconcurrency import AVFoundation
import Foundation
import RecorderCore

/// AVAudioEngine でマイクを録り、segmentDuration 秒ごとに独立した m4a（AAC）に区切って書く。
///
/// - 区切りごとにファイルを閉じるので、アプリが落ちても失うのは書きかけの1区切りだけ
/// - 電話などの割り込みで止まったら、そこで区切りを閉じ、割り込みが終われば新しい区切りから再開する
/// - イヤホンの抜き差しなどで入力形式が変わったら、区切りを閉じて新しい形式で続ける
public final class SegmentedAudioRecorder: AudioCapturing, @unchecked Sendable {
    public struct Settings: Sendable {
        public var segmentDuration: TimeInterval
        public var bitRate: Int
        public init(segmentDuration: TimeInterval = 30, bitRate: Int = 64_000) {
            self.segmentDuration = segmentDuration
            self.bitRate = bitRate
        }
    }

    private let settings: Settings
    private let session: AudioSessionControlling
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var planner: SegmentPlanner?
    private var file: AVAudioFile?
    private var segmentURL: ((Int) throws -> URL)?
    private var onEvent: (@Sendable (CaptureEvent) -> Void)?
    private var running = false
    private var paused = false
    private var observers: [NSObjectProtocol] = []

    public init(settings: Settings = Settings(), session: AudioSessionControlling = AudioSessionController()) {
        self.settings = settings
        self.session = session
    }

    public var isRunning: Bool { lock.withLock { running } }

    public func start(firstIndex: Int, segmentURL: @escaping (Int) throws -> URL,
                      onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        try lock.withLock {
            guard !running else { return }
            try session.activateForRecording()
            self.segmentURL = segmentURL
            self.onEvent = onEvent
            let format = engine.inputNode.outputFormat(forBus: 0)
            planner = SegmentPlanner(segmentDuration: settings.segmentDuration, sampleRate: format.sampleRate,
                                     firstIndex: firstIndex)
            try startEngineLocked()
            running = true
            paused = false
        }
        observeSystemNotifications()
    }

    public func stop() {
        let closed: (Int, TimeInterval, TimeInterval)? = lock.withLock {
            guard running else { return nil }
            running = false
            stopEngineLocked()
            return closeFileLocked()
        }
        removeObservers()
        if let closed { onEvent?(.segmentFinished(index: closed.0, startOffset: closed.1, duration: closed.2)) }
        session.deactivate()
    }

    // MARK: エンジン

    /// lock を持った状態で呼ぶ。
    private func startEngineLocked() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        if planner?.sampleRate != format.sampleRate { planner?.updateSampleRate(format.sampleRate) }
        try openFileLocked(format: format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.write(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngineLocked() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func openFileLocked(format: AVAudioFormat) throws {
        guard let planner, let segmentURL else { return }
        let url = try segmentURL(planner.currentIndex)
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: settings.bitRate,
        ]
        file = try AVAudioFile(forWriting: url, settings: fileSettings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// ファイルを閉じて、閉じた区切りを返す。AVAudioFile は解放したときに書き終わる。
    private func closeFileLocked() -> (Int, TimeInterval, TimeInterval)? {
        file = nil
        guard let closed = planner?.closeCurrent() else { return nil }
        return (closed.index, closed.startOffset, closed.duration)
    }

    /// タップから呼ばれる（オーディオのスレッド）。
    private func write(_ buffer: AVAudioPCMBuffer) {
        var finished: (Int, TimeInterval, TimeInterval)?
        var failure: String?
        lock.withLock {
            guard running, !paused, let file else { return }
            do {
                try file.write(from: buffer)
                if planner?.didWrite(frames: Int(buffer.frameLength)) == true {
                    finished = closeFileLocked()
                    try openFileLocked(format: buffer.format)
                }
            } catch {
                failure = String(describing: error)
            }
        }
        if let finished { onEvent?(.segmentFinished(index: finished.0, startOffset: finished.1, duration: finished.2)) }
        if let failure {
            onEvent?(.failed(message: failure))
            stop()
        }
    }

    // MARK: 割り込み・経路変更

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: nil) { [weak self] _ in
            self?.restartAfterChange()
        })
        #endif
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: nil) { [weak self] _ in
            self?.restartAfterChange()
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            let closed: (Int, TimeInterval, TimeInterval)? = lock.withLock {
                guard running, !paused else { return nil }
                paused = true
                stopEngineLocked()
                return closeFileLocked()
            }
            if let closed { onEvent?(.segmentFinished(index: closed.0, startOffset: closed.1, duration: closed.2)) }
            onEvent?(.interrupted)
        case .ended:
            // shouldResume が無くても、録音アプリなので再開を試みる
            resumeAfterInterruption()
        @unknown default:
            break
        }
    }
    #endif

    private func resumeAfterInterruption() {
        var resumed = false
        var failure: String?
        lock.withLock {
            guard running, paused else { return }
            do {
                try session.activateForRecording()
                try startEngineLocked()
                paused = false
                resumed = true
            } catch {
                failure = String(describing: error)
            }
        }
        if resumed { onEvent?(.resumed) }
        if let failure { onEvent?(.failed(message: "割り込み後に再開できませんでした: \(failure)")) }
    }

    /// 入力形式が変わった・メディアサービスが再起動した。区切りを閉じて新しい形式で録り直す。
    private func restartAfterChange() {
        var closed: (Int, TimeInterval, TimeInterval)?
        var failure: String?
        lock.withLock {
            guard running, !paused else { return }
            stopEngineLocked()
            closed = closeFileLocked()
            do {
                try session.activateForRecording()
                try startEngineLocked()
            } catch {
                failure = String(describing: error)
                paused = true // 次の割り込み終了で再開を試みる
            }
        }
        if let closed { onEvent?(.segmentFinished(index: closed.0, startOffset: closed.1, duration: closed.2)) }
        if let failure { onEvent?(.failed(message: "入力の切り替え後に再開できませんでした: \(failure)")) }
    }
}

public enum CaptureError: Error, Equatable {
    case noInput
    case permissionDenied
}
