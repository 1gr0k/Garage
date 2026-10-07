import Foundation

/// Wire representation of a vehicle. `kind` is `car|motorcycle|bicycle`.
public struct VehicleDTO: Hashable, Sendable, Codable {
    public var id: UUID
    public var kind: String
    public var make: String
    public var model: String
    public var year: Int
    public var mileageKm: Int

    public init(id: UUID, kind: String, make: String, model: String, year: Int, mileageKm: Int) {
        self.id = id
        self.kind = kind
        self.make = make
        self.model = model
        self.year = year
        self.mileageKm = mileageKm
    }
}

/// Wire representation of a part. Parts have no sync of their own: they are embedded in a record.
public struct PartDTO: Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var partNumber: String?
    public var unitPriceKopecks: Int
    public var quantity: Int

    public init(id: UUID, name: String, partNumber: String? = nil, unitPriceKopecks: Int, quantity: Int) {
        self.id = id
        self.name = name
        self.partNumber = partNumber
        self.unitPriceKopecks = unitPriceKopecks
        self.quantity = quantity
    }
}

/// Reference to a receipt photo stored content-addressed under `/v1/receipts/{sha256}`.
public struct ReceiptRefDTO: Hashable, Sendable, Codable {
    public var sha256: String
    public var byteCount: Int

    public init(sha256: String, byteCount: Int) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Wire representation of a service record. `serviceType` is a `ServiceType.storageString`;
/// consumers must read unknown values as `.other(<string>)`.
public struct ServiceRecordDTO: Hashable, Sendable, Codable {
    public var id: UUID
    public var vehicleID: UUID
    public var date: Date
    public var mileageKm: Int
    public var serviceType: String
    public var laborCostKopecks: Int
    public var notes: String
    public var parts: [PartDTO]
    public var receipt: ReceiptRefDTO?

    public init(
        id: UUID,
        vehicleID: UUID,
        date: Date,
        mileageKm: Int,
        serviceType: String,
        laborCostKopecks: Int,
        notes: String,
        parts: [PartDTO],
        receipt: ReceiptRefDTO? = nil
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.date = date
        self.mileageKm = mileageKm
        self.serviceType = serviceType
        self.laborCostKopecks = laborCostKopecks
        self.notes = notes
        self.parts = parts
        self.receipt = receipt
    }
}
