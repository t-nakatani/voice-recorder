import Foundation

/// バケット内のキーの決め方。同じものを何度送っても同じキーになるので、再送は上書きになるだけで壊れない。
/// Worker 側の検証（ingest/src/keys.ts）と形を揃えること。
public enum ObjectKeys {
    public static func segment(_ recordingID: RecordingID, index: Int, fileExtension: String) -> String {
        "recordings/\(recordingID.rawValue)/segments/\(String(format: "%06d", index)).\(fileExtension)"
    }

    public static func manifest(_ recordingID: RecordingID) -> String {
        "recordings/\(recordingID.rawValue)/manifest.json"
    }

    public static func key(for item: UploadItem, of recording: Recording) -> String {
        switch item {
        case .segment(let index):
            return segment(recording.id, index: index, fileExtension: recording.format.fileExtension)
        case .manifest:
            return manifest(recording.id)
        }
    }
}
