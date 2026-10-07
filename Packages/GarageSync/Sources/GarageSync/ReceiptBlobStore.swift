import Foundation
import GarageAPI

/// Local receipt photo bytes as the sync engine sees them (the blobs themselves are not part of `SyncStore`).
public protocol ReceiptBlobStore: Sendable {
    /// The local bytes to upload for a receipt hash; `nil` means there is nothing to upload
    /// (the server presumably has the blob already).
    func receiptData(sha256: String) async throws -> Data?
    /// References from synced records whose bytes are not stored locally yet.
    func missingReceipts() async throws -> [ReceiptRefDTO]
    /// Stores downloaded bytes. The implementation verifies hash and size and throws on a mismatch.
    func storeReceipt(_ data: Data, for ref: ReceiptRefDTO) async throws
}
