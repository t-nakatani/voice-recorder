import Foundation
import RecorderCore

/// 録音をファイルとして保存する RecordingStore の実装。
///
/// 置き方（root はアプリの App Group コンテナ配下）:
/// ```
/// root/recordings/<録音ID>/recording.json        台帳（原子的に書き換える）
/// root/recordings/<録音ID>/segments/000000.m4a  閉じた区切り
/// root/recordings/<録音ID>/segments/000001.partial.m4a  書きかけ（拡張子を .m4a にしておかないと AVAudioFile が CAF で書く）
/// root/recordings/<録音ID>/manifest.json         録音を閉じたときに書く
/// root/recordings/<録音ID>/damaged/              復旧できなかった書きかけ（消さずに残す）
/// ```
/// 原則: ファイルを書き終えて名前を確定してから台帳に載せる。台帳にあるものは必ず実ファイルがある。
public final class FileRecordingStore: RecordingStore, @unchecked Sendable {
    public let root: URL
    private let fileManager: FileManager
    private let clock: Clock
    private let lock = NSLock()

    public init(root: URL, fileManager: FileManager = .default, clock: Clock = SystemClock()) throws {
        self.root = root
        self.fileManager = fileManager
        self.clock = clock
        try Self.makeDirectory(Self.recordingsRoot(root), fileManager: fileManager)
    }

    // MARK: RecordingStore

    public func createRecording(id: RecordingID, startedAt: Date, format: AudioFormat) throws -> Recording {
        try lock.withLock {
            let dir = directory(for: id)
            guard !fileManager.fileExists(atPath: ledgerURL(for: id).path) else {
                throw StoreError.alreadyExists(id)
            }
            try Self.makeDirectory(dir.appendingPathComponent("segments", isDirectory: true), fileManager: fileManager)
            let recording = Recording(id: id, startedAt: startedAt, status: .recording, format: format)
            return try writeLedger(recording)
        }
    }

    public func pendingSegmentURL(recordingID: RecordingID, index: Int) throws -> URL {
        try lock.withLock {
            let recording = try readLedger(recordingID)
            return partialURL(recordingID, index: index, ext: recording.format.fileExtension)
        }
    }

    @discardableResult
    public func commitSegment(recordingID: RecordingID, index: Int, startOffset: TimeInterval,
                              duration: TimeInterval) throws -> Segment {
        try lock.withLock {
            var recording = try readLedger(recordingID)
            if let existing = recording.segments.first(where: { $0.index == index }) {
                return existing // 二重に呼ばれても同じ結果
            }
            let ext = recording.format.fileExtension
            // 古い版が残した書きかけ（000001.m4a.partial）も拾う
            let partial = [partialURL(recordingID, index: index, ext: ext),
                           legacyPartialURL(recordingID, index: index, ext: ext)]
                .first { fileManager.fileExists(atPath: $0.path) } ?? partialURL(recordingID, index: index, ext: ext)
            let final = segmentURL(recordingID, index: index, ext: ext)
            if fileManager.fileExists(atPath: partial.path) {
                if fileManager.fileExists(atPath: final.path) { try fileManager.removeItem(at: final) }
                try fileManager.moveItem(at: partial, to: final)
                Self.applyProtection(final, fileManager: fileManager)
            } else if !fileManager.fileExists(atPath: final.path) {
                // 名前の確定までは済んで台帳への書き込みだけが失敗した場合は、確定済みのファイルをそのまま台帳に載せる
                throw StoreError.missingFile(partial)
            }

            let (hex, bytes) = try FileHashing.sha256(of: final)
            let segment = Segment(index: index, fileName: final.lastPathComponent, startOffset: startOffset,
                                  duration: duration, byteCount: bytes, sha256: hex, committedAt: clock.now())
            recording.segments.append(segment)
            recording.segments.sort { $0.index < $1.index }
            let stored = try writeLedger(recording)
            return stored.segments.first(where: { $0.index == index }) ?? segment
        }
    }

    @discardableResult
    public func closeRecording(id: RecordingID, endedAt: Date, status: RecordingStatus) throws -> Recording {
        precondition(status != .recording, "closeRecording には終了後の状態を渡す")
        return try lock.withLock {
            var recording = try readLedger(id)
            recording.status = status
            recording.endedAt = endedAt
            try writeManifest(for: recording)
            return try writeLedger(recording)
        }
    }

    public func recording(id: RecordingID) throws -> Recording? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: ledgerURL(for: id).path) else { return nil }
            return try readLedger(id)
        }
    }

    public func allRecordings() throws -> [Recording] {
        try lock.withLock {
            let dirs = (try? fileManager.contentsOfDirectory(at: Self.recordingsRoot(root),
                                                              includingPropertiesForKeys: nil)) ?? []
            return dirs.compactMap { dir in
                try? readLedger(RecordingID(rawValue: dir.lastPathComponent))
            }.sorted { $0.id > $1.id }
        }
    }

    public func fileURL(for item: UploadItem, of recordingID: RecordingID) throws -> URL {
        try lock.withLock {
            let recording = try readLedger(recordingID)
            switch item {
            case .segment(let index):
                guard recording.segments.contains(where: { $0.index == index }) else {
                    throw StoreError.unknownSegment(recordingID, index)
                }
                return segmentURL(recordingID, index: index, ext: recording.format.fileExtension)
            case .manifest:
                let url = manifestURL(for: recordingID)
                guard fileManager.fileExists(atPath: url.path) else { throw StoreError.missingFile(url) }
                return url
            }
        }
    }

    public func deleteRecording(id: RecordingID) throws {
        try lock.withLock {
            let dir = directory(for: id)
            if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
        }
    }

    // MARK: 復旧

    /// 起動時に呼ぶ。録音中のまま残った録音（アプリが落ちた等）を閉じる。
    /// - Parameters:
    ///   - activeID: 今まさに録音中のID（これは触らない）
    ///   - probeDuration: 書きかけファイルが再生できるか調べ、できれば長さ（秒）を返す。AudioCapture が提供する。
    /// - Returns: 閉じた録音
    @discardableResult
    public func recoverUnclosedRecordings(except activeID: RecordingID?,
                                          probeDuration: (URL) -> TimeInterval?) throws -> [Recording] {
        let candidates = try allRecordings().filter { $0.status == .recording && $0.id != activeID }
        var recovered: [Recording] = []
        for recording in candidates {
            try commitLeftoverSegments(recordingID: recording.id, probeDuration: probeDuration)
            let latest = try readLedgerLocked(recording.id)
            let endedAt = latest.segments.last?.committedAt ?? latest.startedAt
            recovered.append(try closeRecording(id: recording.id, endedAt: max(endedAt, latest.startedAt),
                                                status: .interrupted))
        }
        return recovered
    }

    /// 台帳に載っていない区切りファイルを拾って台帳に載せる。録音を閉じる前と、起動時の復旧で呼ぶ。
    /// - 書きかけ（000001.partial.m4a、古い版の 000001.m4a.partial）: 読めれば載せ、読めなければ `damaged/` に移す（消さない）
    /// - 名前は確定したのに台帳に載っていないもの（台帳の書き込みだけ失敗した）: 読めれば載せる
    /// - Returns: 新しく載せた区切り
    @discardableResult
    public func commitLeftoverSegments(recordingID: RecordingID,
                                       probeDuration: (URL) -> TimeInterval?) throws -> [Segment] {
        let recording = try readLedgerLocked(recordingID)
        let known = Set(recording.segments.map(\.index))
        let segmentsDir = directory(for: recordingID).appendingPathComponent("segments", isDirectory: true)
        let files = (try? fileManager.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)) ?? []

        // 区切り番号 → 拾うファイル（同じ番号に確定済みと書きかけの両方があれば書きかけを優先して commit が上書きする）
        var leftovers: [Int: URL] = [:]
        for file in files {
            if let index = Self.segmentIndex(fromPartial: file, ext: recording.format.fileExtension) {
                if known.contains(index) { try quarantine(file, of: recordingID) } else { leftovers[index] = file }
            } else if file.pathExtension == recording.format.fileExtension,
                      let index = Int(file.deletingPathExtension().lastPathComponent),
                      !known.contains(index), leftovers[index] == nil {
                leftovers[index] = file
            }
        }

        var committed: [Segment] = []
        for index in leftovers.keys.sorted() {
            let file = leftovers[index]!
            guard let duration = probeDuration(file), duration > 0 else {
                try quarantine(file, of: recordingID)
                continue
            }
            let current = try readLedgerLocked(recordingID)
            // 開始位置は、番号がこれより小さい区切りの長さの合計
            let offset = current.segments.filter { $0.index < index }.reduce(0) { $0 + $1.duration }
            committed.append(try commitSegment(recordingID: recordingID, index: index,
                                               startOffset: offset, duration: duration))
        }
        return committed
    }

    private func readLedgerLocked(_ id: RecordingID) throws -> Recording {
        try lock.withLock { try readLedger(id) }
    }

    // MARK: パス

    static func recordingsRoot(_ root: URL) -> URL { root.appendingPathComponent("recordings", isDirectory: true) }
    func directory(for id: RecordingID) -> URL {
        Self.recordingsRoot(root).appendingPathComponent(id.rawValue, isDirectory: true)
    }
    func ledgerURL(for id: RecordingID) -> URL { directory(for: id).appendingPathComponent("recording.json") }
    func manifestURL(for id: RecordingID) -> URL { directory(for: id).appendingPathComponent("manifest.json") }
    func segmentURL(_ id: RecordingID, index: Int, ext: String) -> URL {
        directory(for: id).appendingPathComponent("segments/\(String(format: "%06d", index)).\(ext)")
    }
    /// 書きかけの名前。最後の拡張子を録音の形式（m4a）にする。AVAudioFile は拡張子から入れ物を決めるため、
    /// `.partial` で終わる名前だと AAC を CAF の入れ物で書いてしまう。
    func partialURL(_ id: RecordingID, index: Int, ext: String) -> URL {
        directory(for: id).appendingPathComponent("segments/\(String(format: "%06d", index)).partial.\(ext)")
    }
    /// 古い版の書きかけの名前（000003.m4a.partial）。中身は CAF だが、復旧では読めれば拾う。
    func legacyPartialURL(_ id: RecordingID, index: Int, ext: String) -> URL {
        segmentURL(id, index: index, ext: ext).appendingPathExtension("partial")
    }

    /// 書きかけのファイルなら区切り番号を返す。000003.partial.m4a と 000003.m4a.partial -> 3
    static func segmentIndex(fromPartial url: URL, ext: String) -> Int? {
        let name = url.lastPathComponent
        for suffix in [".partial.\(ext)", ".\(ext).partial"] where name.hasSuffix(suffix) {
            return Int(name.dropLast(suffix.count))
        }
        return nil
    }

    // MARK: 読み書き

    private func readLedger(_ id: RecordingID) throws -> Recording {
        let url = ledgerURL(for: id)
        guard let data = fileManager.contents(atPath: url.path) else { throw StoreError.unknownRecording(id) }
        return try Self.decoder.decode(Recording.self, from: data)
    }

    /// 台帳を書き、書いた内容を読み直して返す。
    /// 日付は ISO 8601（秒まで）で保存されるので、呼び出し元へは保存後の値を返し、読み直した値と一致させる。
    @discardableResult
    private func writeLedger(_ recording: Recording) throws -> Recording {
        let data = try Self.encoder.encode(recording)
        try Self.atomicWrite(data, to: ledgerURL(for: recording.id))
        return try Self.decoder.decode(Recording.self, from: data)
    }

    private func writeManifest(for recording: Recording) throws {
        let data = try RecordingManifest.encoder().encode(RecordingManifest(recording: recording))
        try Self.atomicWrite(data, to: manifestURL(for: recording.id))
    }

    private func quarantine(_ partial: URL, of id: RecordingID) throws {
        let damaged = directory(for: id).appendingPathComponent("damaged", isDirectory: true)
        try Self.makeDirectory(damaged, fileManager: fileManager)
        let target = damaged.appendingPathComponent(partial.lastPathComponent)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: partial, to: target)
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    /// ロック中でも書けて読める保護クラス（初回ロック解除後〜）にする。
    /// これより厳しい .complete にすると、ロック中の録音・送信が失敗する。
    static func applyProtection(_ url: URL, fileManager: FileManager) {
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                       ofItemAtPath: url.path)
        #endif
    }

    static func makeDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        applyProtection(url, fileManager: fileManager)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case alreadyExists(RecordingID)
    case unknownRecording(RecordingID)
    case unknownSegment(RecordingID, Int)
    case missingFile(URL)

    public var description: String {
        switch self {
        case .alreadyExists(let id): return "録音 \(id) は既にあります"
        case .unknownRecording(let id): return "録音 \(id) が見つかりません"
        case .unknownSegment(let id, let index): return "録音 \(id) の区切り \(index) が台帳にありません"
        case .missingFile(let url): return "ファイルがありません: \(url.lastPathComponent)"
        }
    }
}
