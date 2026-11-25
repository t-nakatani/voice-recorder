import CryptoKit
import Foundation

public enum FileHashing {
    /// ファイルを 1MB ずつ読んで SHA-256 を計算する。返り値は (小文字16進, バイト数)。
    public static func sha256(of url: URL) throws -> (hex: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize()
        return (digest.map { String(format: "%02x", $0) }.joined(), total)
    }

    /// 16進の SHA-256 を、x-amz-checksum-sha256 ヘッダー用の base64 に変える。
    public static func base64(fromHex hex: String) -> String? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }
}
