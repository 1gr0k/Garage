import Foundation
import SwiftData

@Model
public final class PartEntity {
    @Attribute(.unique) public var id: UUID
    public var record: ServiceRecordEntity?
    public var name: String
    public var partNumber: String?
    public var unitPriceKopecks: Int
    public var quantity: Int
    /// To-many relationships are unordered in SwiftData; this restores `ServiceRecord.parts` order.
    public var sortIndex: Int

    init(
        id: UUID,
        name: String,
        partNumber: String?,
        unitPriceKopecks: Int,
        quantity: Int,
        sortIndex: Int
    ) {
        self.id = id
        self.name = name
        self.partNumber = partNumber
        self.unitPriceKopecks = unitPriceKopecks
        self.quantity = quantity
        self.sortIndex = sortIndex
    }
}
