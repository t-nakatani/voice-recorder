import AVFoundation
import Foundation

/// ファイルが音声として読めるかを調べ、読めれば長さ（秒）を返す。
/// アプリが落ちて残った書きかけファイルの復旧判定に使う（FileRecordingStore.recoverUnclosedRecordings）。
public enum AudioFileProbe {
    public static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
}
