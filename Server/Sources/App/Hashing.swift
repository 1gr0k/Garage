import Crypto
import Foundation

enum Hashing {
    static func sha256Hex(_ data: some DataProtocol) -> String {
        hex(SHA256.hash(data: data))
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    /// Equality of the SHA-256 digests of two strings; swift-crypto compares digests in constant time.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        SHA256.hash(data: Data(lhs.utf8)) == SHA256.hash(data: Data(rhs.utf8))
    }

    /// 32 random bytes as base64url without padding (43 characters).
    static func makeToken() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 64 lowercase hex characters.
    static func isSHA256Hex(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(64)
        for byte in digest {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return result
    }
}
