import Foundation
import GarageSync
import SwiftData

/// Правило обслуживания машины. Удаляется каскадом вместе с `VehicleEntity`.
@Model
public final class MaintenanceRuleEntity {
    @Attribute(.unique) public var id: UUID
    public var vehicle: VehicleEntity?
    /// `ServiceType.storageString` (для незнакомого серверного типа — `other:<строка>`).
    public var serviceTypeRaw: String
    /// Исходная строка `serviceType`, если сервер прислал тип, которого клиент не знает.
    public var rawServiceType: String?
    /// `ServicePeriod.storageString` известного интервала по времени; `nil` — интервала по времени нет.
    public var periodRaw: String?
    /// Исходная строка `period`, которую клиент не понял (`"weeks:2"`): в домене `period == nil`, строка уходит на
    /// сервер без изменений, пока пользователь явно не тронул интервал по времени (`MaintenancePeriodChange`).
    public var rawPeriod: String?
    public var distanceKm: Int?
    public var startDate: Date
    public var startMileageKm: Int

    init(
        id: UUID,
        vehicle: VehicleEntity?,
        serviceTypeRaw: String,
        periodRaw: String?,
        distanceKm: Int?,
        startDate: Date,
        startMileageKm: Int
    ) {
        self.id = id
        self.vehicle = vehicle
        self.serviceTypeRaw = serviceTypeRaw
        self.periodRaw = periodRaw
        self.distanceKm = distanceKm
        self.startDate = startDate
        self.startMileageKm = startMileageKm
    }

    /// Что синхронизация хранит рядом с доменным правилом.
    var syncExtras: RuleSyncExtras {
        RuleSyncExtras(rawServiceType: rawServiceType, rawPeriod: rawPeriod)
    }
}
