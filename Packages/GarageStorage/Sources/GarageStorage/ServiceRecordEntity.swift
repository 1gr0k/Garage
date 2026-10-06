import Foundation
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
    /// Whether a receipt photo is attached; lets lists avoid loading `receiptImage` just to check.
    /// The default lets lightweight migration add the column to existing stores.
    public private(set) var hasReceipt: Bool = false
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

    /// Attaches, replaces or (with `nil`) removes the receipt photo, keeping `hasReceipt` in sync.
    public func setReceiptImage(_ data: Data?) {
        receiptImage = data
        hasReceipt = data != nil
    }
}
