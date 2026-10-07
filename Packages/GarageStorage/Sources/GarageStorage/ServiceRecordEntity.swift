import CryptoKit
import Foundation
import GarageAPI
import GarageSync
import SwiftData

@Model
public final class ServiceRecordEntity {
    @Attribute(.unique) public var id: UUID
    public var vehicle: VehicleEntity?
    public var date: Date
    public var mileageKm: Int
    public var serviceTypeRaw: String
    public var laborCostKopecks: Int
    public var notes: String
    /// Receipt photo, kept in storage only: the domain model knows nothing about it.
    @Attribute(.externalStorage) public private(set) var receiptImage: Data?
    /// Whether a receipt is attached (`receiptSHA256 != nil`); lets lists avoid loading `receiptImage` just to check.
    /// It stays `true` while the bytes of a synced receipt are still being downloaded.
    /// The default lets lightweight migration add the column to existing stores.
    /// Existing records are not backfilled: the app isn't released yet, so there is no real data.
    /// Once there is, add a `SchemaMigrationPlan` that sets `hasReceipt = receiptImage != nil`.
    public private(set) var hasReceipt: Bool = false
    /// Content address of the receipt photo (lowercase hex SHA-256), as the sync API refers to it.
    /// Old records get it from `SyncBootstrap`.
    public private(set) var receiptSHA256: String?
    public private(set) var receiptByteCount: Int?
    /// The original `serviceType` string when the server sent a type this client does not know.
    public var rawServiceType: String?
    /// The record refers to a receipt (from the server) whose bytes are not stored yet.
    public private(set) var receiptNeedsDownload: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \PartEntity.record)
    public var parts: [PartEntity] = []

    init(
        id: UUID,
        vehicle: VehicleEntity?,
        date: Date,
        mileageKm: Int,
        serviceTypeRaw: String,
        laborCostKopecks: Int,
        notes: String
    ) {
        self.id = id
        self.vehicle = vehicle
        self.date = date
        self.mileageKm = mileageKm
        self.serviceTypeRaw = serviceTypeRaw
        self.laborCostKopecks = laborCostKopecks
        self.notes = notes
    }

    /// Attaches, replaces or (with `nil`) removes the receipt photo, keeping the derived fields in sync.
    public func setReceiptImage(_ data: Data?) {
        receiptImage = data
        receiptSHA256 = data.map(Self.sha256Hex)
        receiptByteCount = data?.count
        hasReceipt = data != nil
        receiptNeedsDownload = false
    }

    /// Applies the receipt reference of a synced record. Bytes that already match are kept;
    /// otherwise the photo is dropped and marked for download.
    public func setReceiptRef(_ ref: ReceiptRefDTO?) {
        guard let ref else {
            setReceiptImage(nil)
            return
        }
        if receiptSHA256 == ref.sha256, receiptImage != nil {
            receiptByteCount = ref.byteCount
            receiptNeedsDownload = false
        } else {
            receiptImage = nil
            receiptSHA256 = ref.sha256
            receiptByteCount = ref.byteCount
            receiptNeedsDownload = true
        }
        hasReceipt = true
    }

    /// Stores downloaded bytes for the current `receiptSHA256` (the caller has verified them).
    func storeDownloadedReceipt(_ data: Data) {
        receiptImage = data
        receiptNeedsDownload = false
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What sync keeps next to the domain record.
    var syncExtras: RecordSyncExtras {
        RecordSyncExtras(
            receipt: receiptSHA256.map {
                ReceiptRefDTO(sha256: $0, byteCount: receiptByteCount ?? receiptImage?.count ?? 0)
            },
            rawServiceType: rawServiceType)
    }
}
