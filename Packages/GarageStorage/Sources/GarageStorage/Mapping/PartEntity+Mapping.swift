import Foundation
import GarageCore

extension PartEntity {
    public convenience init(_ part: Part, sortIndex: Int) {
        self.init(
            id: part.id,
            name: part.name,
            partNumber: part.partNumber,
            unitPriceKopecks: part.unitPrice.kopecks,
            quantity: part.quantity,
            sortIndex: sortIndex
        )
    }

    public func update(from part: Part, sortIndex: Int) {
        name = part.name
        partNumber = part.partNumber
        unitPriceKopecks = part.unitPrice.kopecks
        quantity = part.quantity
        self.sortIndex = sortIndex
    }

    public func toDomain() throws -> Part {
        try Part(
            id: id,
            name: name,
            partNumber: partNumber,
            unitPrice: Money(kopecks: unitPriceKopecks),
            quantity: quantity
        )
    }
}
