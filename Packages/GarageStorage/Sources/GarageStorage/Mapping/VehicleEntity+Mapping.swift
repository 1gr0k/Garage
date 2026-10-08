import Foundation
import GarageCore

extension VehicleEntity {
    public convenience init(_ vehicle: Vehicle) {
        self.init(
            id: vehicle.id,
            kindRaw: vehicle.kind.rawValue,
            make: vehicle.make,
            model: vehicle.model,
            year: vehicle.year,
            mileageKm: vehicle.mileageKm
        )
    }

    /// Обновляет скалярные поля. `rawKind` не трогает: его меняют явно (`VehicleKindChange`, ответ сервера).
    public func update(from vehicle: Vehicle) {
        kindRaw = vehicle.kind.rawValue
        make = vehicle.make
        model = vehicle.model
        year = vehicle.year
        mileageKm = vehicle.mileageKm
    }

    public func toDomain() throws -> Vehicle {
        guard let kind = VehicleKind(rawValue: kindRaw) else {
            throw StorageMappingError.unknownVehicleKind(kindRaw)
        }
        return try Vehicle(
            id: id,
            kind: kind,
            make: make,
            model: model,
            year: year,
            mileageKm: mileageKm
        )
    }
}
