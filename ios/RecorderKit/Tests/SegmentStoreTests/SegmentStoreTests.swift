import Foundation
import RecorderCore
import Testing
@testable import SegmentStore

@Suite struct SegmentStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
    let id = RecordingID(rawValue: "20261125T000000Z-00000001")

    private func writeSegment(_ store: FileRecordingStore, index: Int, bytes: String = "audio") throws {
        let url = try store.pendingSegmentURL(recordingID: id, index: index)
        try Data(bytes.utf8).write(to: url)
    }

    @Test func lifecycleWritesLedgerSegmentsAndManifest() throws {
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        try writeSegment(store, index: 0)
        let segment = try store.commitSegment(recordingID: id, index: 0, startOffset: 0, duration: 30)
        #expect(segment.byteCount == 5)
        #expect(segment.fileName == "000000.m4a")

        // 書きかけの拡張子は消え、確定した名前で残る
        let final = try store.fileURL(for: .segment(0), of: id)
        #expect(FileManager.default.fileExists(atPath: final.path))
        let partial = try store.pendingSegmentURL(recordingID: id, index: 0)
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        let closed = try store.closeRecording(id: id, endedAt: Date(), status: .finished)
        #expect(closed.status == .finished)
        let manifestURL = try store.fileURL(for: .manifest, of: id)
        let manifest = try JSONDecoder.iso.decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.segments.count == 1)

        // 別インスタンスで読み直しても同じ
        let reopened = try FileRecordingStore(root: root)
        #expect(try reopened.recording(id: id) == closed)
    }

    @Test func commitIsIdempotent() throws {
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        try writeSegment(store, index: 0)
        let first = try store.commitSegment(recordingID: id, index: 0, startOffset: 0, duration: 30)
        let second = try store.commitSegment(recordingID: id, index: 0, startOffset: 0, duration: 30)
        #expect(first == second)
        #expect(try store.recording(id: id)?.segments.count == 1)
    }

    @Test func commitWithoutFileFails() throws {
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        #expect(throws: StoreError.self) {
            try store.commitSegment(recordingID: id, index: 3, startOffset: 0, duration: 1)
        }
    }

    @Test func recoveryCommitsPlayablePartialsAndKeepsBrokenOnes() throws {
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        try writeSegment(store, index: 0)
        try store.commitSegment(recordingID: id, index: 0, startOffset: 0, duration: 30)
        try writeSegment(store, index: 1, bytes: "playable")
        try writeSegment(store, index: 2, bytes: "broken")

        let recovered = try store.recoverUnclosedRecordings(except: nil) { url in
            url.lastPathComponent.hasPrefix("000001") ? 12 : nil
        }
        #expect(recovered.count == 1)
        let recording = try #require(try store.recording(id: id))
        #expect(recording.status == .interrupted)
        #expect(recording.segments.map(\.index) == [0, 1])
        #expect(recording.segments[1].startOffset == 30)
        let damaged = root.appendingPathComponent("recordings/\(id.rawValue)/damaged/000002.partial.m4a")
        #expect(FileManager.default.fileExists(atPath: damaged.path)) // 消さずに残す
    }

    @Test func finalizedFileMissingFromLedgerIsAdopted() throws {
        // 名前の確定（.partial → .m4a）の後、台帳を書く前に落ちた場合
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        try writeSegment(store, index: 0)
        try store.commitSegment(recordingID: id, index: 0, startOffset: 0, duration: 30)
        let orphan = root.appendingPathComponent("recordings/\(id.rawValue)/segments/000001.m4a")
        try Data("orphan".utf8).write(to: orphan)

        let adopted = try store.commitLeftoverSegments(recordingID: id) { _ in 20 }
        #expect(adopted.map(\.index) == [1])
        #expect(adopted.first?.startOffset == 30)
        #expect(adopted.first?.byteCount == 6)
        #expect(try store.recording(id: id)?.segments.map(\.index) == [0, 1])
        // 2回目は何も拾わない
        #expect(try store.commitLeftoverSegments(recordingID: id) { _ in 20 }.isEmpty)
    }

    @Test func leftoverOffsetsFollowIndexOrder() throws {
        // 区切り 1 の台帳への登録だけが失敗し、区切り 2 は載った場合
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        for index in 0...2 { try writeSegment(store, index: index) }
        try store.commitSegment(recordingID: id, index: 0, startOffset: 0, duration: 30)
        try store.commitSegment(recordingID: id, index: 2, startOffset: 60, duration: 30)

        let adopted = try store.commitLeftoverSegments(recordingID: id) { _ in 30 }
        #expect(adopted.map(\.index) == [1])
        #expect(adopted.first?.startOffset == 30)
    }

    @Test func recoverySkipsActiveRecording() throws {
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        let recovered = try store.recoverUnclosedRecordings(except: id) { _ in nil }
        #expect(recovered.isEmpty)
        #expect(try store.recording(id: id)?.status == .recording)
    }

    @Test func retentionNeverDeletesByDefault() {
        let now = Date()
        let old = Recording(id: id, startedAt: now.addingTimeInterval(-1_000_000), endedAt: now.addingTimeInterval(-999_000),
                            status: .finished, format: .aacMono64k)
        #expect(!RetentionPolicy.keepForever.mayDelete(old, fullyDelivered: true, now: now))
        let weekly = RetentionPolicy(keepDeliveredFor: 7 * 86_400)
        #expect(weekly.mayDelete(old, fullyDelivered: true, now: now))
        #expect(!weekly.mayDelete(old, fullyDelivered: false, now: now))
        var open = old
        open.status = .recording
        #expect(!weekly.mayDelete(open, fullyDelivered: true, now: now))
    }

    @Test func pendingSegmentKeepsFormatExtension() throws {
        // AVAudioFile は拡張子から入れ物を決める。最後が .m4a でないと CAF で書かれる
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        let url = try store.pendingSegmentURL(recordingID: id, index: 3)
        #expect(url.lastPathComponent == "000003.partial.m4a")
        #expect(url.pathExtension == "m4a")
        #expect(FileRecordingStore.segmentIndex(fromPartial: url, ext: "m4a") == 3)
        #expect(FileRecordingStore.segmentIndex(fromPartial: URL(fileURLWithPath: "/x/000004.m4a.partial"), ext: "m4a") == 4)
        #expect(FileRecordingStore.segmentIndex(fromPartial: URL(fileURLWithPath: "/x/000005.m4a"), ext: "m4a") == nil)
    }

    @Test func legacyPartialIsStillRecovered() throws {
        // 古い版が残した 000001.m4a.partial も拾う
        let store = try FileRecordingStore(root: root)
        _ = try store.createRecording(id: id, startedAt: Date(), format: .aacMono64k)
        try writeSegment(store, index: 0)
        try store.commitSegment(recordingID: id, index: 0, startOffset: 0, duration: 30)
        let legacy = root.appendingPathComponent("recordings/\(id.rawValue)/segments/000001.m4a.partial")
        try Data("legacy".utf8).write(to: legacy)

        let adopted = try store.commitLeftoverSegments(recordingID: id) { _ in 10 }
        #expect(adopted.map(\.index) == [1])
        #expect(adopted.first?.fileName == "000001.m4a")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
