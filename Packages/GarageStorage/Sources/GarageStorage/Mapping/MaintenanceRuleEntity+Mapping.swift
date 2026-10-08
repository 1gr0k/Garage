import Foundation
import GarageCore

extension MaintenanceRuleEntity {
    public convenience init(_ rule: MaintenanceRule, vehicle: VehicleEntity) throws {
        guard rule.vehicleID == vehicle.id else {
            throw StorageMappingError.vehicleMismatch(expected: rule.vehicleID, actual: vehicle.id)
        }
        self.init(
            id: rule.id,
            vehicle: vehicle,
            serviceTypeRaw: rule.serviceType.storageString,
            periodRaw: rule.period?.storageString,
            distanceKm: rule.distanceKm,
            startDate: rule.start.date,
            startMileageKm: rule.start.mileageKm
        )
    }

    /// Обновляет скалярные поля; связь с машиной и сырые значения сервера не трогает.
    public func update(from rule: MaintenanceRule) {
        serviceTypeRaw = rule.serviceType.storageString
        periodRaw = rule.period?.storageString
        distanceKm = rule.distanceKm
        startDate = rule.start.date
        startMileageKm = rule.start.mileageKm
    }

    public func toDomain() throws -> MaintenanceRule {
        guard let vehicle else { throw StorageMappingError.missingVehicle(id) }
        return try MaintenanceRule(
            id: id,
            vehicleID: vehicle.id,
            serviceType: ServiceType(storageString: serviceTypeRaw),
            period: periodRaw.map { try ServicePeriod(storageString: $0) },
            distanceKm: distanceKm,
            start: MaintenanceStart(date: startDate, mileageKm: startMileageKm)
        )
    }
}
