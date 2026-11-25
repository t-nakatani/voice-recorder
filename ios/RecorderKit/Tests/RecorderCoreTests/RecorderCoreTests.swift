import Foundation
import Testing
@testable import RecorderCore

@Suite struct RecorderCoreTests {
    @Test func recordingIDIsSortableAndKeySafe() {
        let early = RecordingID.make(at: Date(timeIntervalSince1970: 1_800_000_000), random: 0xdeadbeef)
        let late = RecordingID.make(at: Date(timeIntervalSince1970: 1_800_000_001), random: 0x00000001)
        #expect(early.rawValue == "20270115T080000Z-deadbeef")
        #expect(early < late)
        #expect(early.rawValue.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    @Test func uploadJobTokenRoundTrips() {
        let id = RecordingID(rawValue: "20261125T091900Z-0000abcd")
        for item in [UploadItem.segment(0), .segment(42), .manifest] {
            let job = UploadJob(recordingID: id, item: item, destination: "r2-primary")
            #expect(UploadJob(token: job.token) == job)
        }
        #expect(UploadJob(token: "broken") == nil)
        #expect(UploadJob(token: "a|segment-x|b") == nil)
    }

    @Test func objectKeysMatchWorkerFormat() {
        let id = RecordingID(rawValue: "20261125T091900Z-0000abcd")
        #expect(ObjectKeys.segment(id, index: 7, fileExtension: "m4a") == "recordings/20261125T091900Z-0000abcd/segments/000007.m4a")
        #expect(ObjectKeys.manifest(id) == "recordings/20261125T091900Z-0000abcd/manifest.json")
    }

    @Test func hexToBase64() {
        // SHA-256("") の16進と base64
        let hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(FileHashing.base64(fromHex: hex) == "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
        #expect(FileHashing.base64(fromHex: "abc") == nil)
    }

    @Test func fileHashing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: url)
        let (hex, bytes) = try FileHashing.sha256(of: url)
        #expect(hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(bytes == 5)
    }

    @Test func manifestListsSegmentsInOrder() {
        let id = RecordingID(rawValue: "r1-abc")
        let now = Date()
        let recording = Recording(id: id, startedAt: now, endedAt: now, status: .finished, format: .aacMono64k, segments: [
            Segment(index: 1, fileName: "000001.m4a", startOffset: 30, duration: 10, byteCount: 2, sha256: "b", committedAt: now),
            Segment(index: 0, fileName: "000000.m4a", startOffset: 0, duration: 30, byteCount: 1, sha256: "a", committedAt: now),
        ])
        let manifest = RecordingManifest(recording: recording)
        #expect(manifest.segments.map(\.index) == [0, 1])
        #expect(manifest.totalDuration == 40)
        #expect(manifest.segments[1].key == "recordings/r1-abc/segments/000001.m4a")
    }
}
