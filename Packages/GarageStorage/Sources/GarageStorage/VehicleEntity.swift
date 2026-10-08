import Foundation
import GarageSync
import SwiftData

@Model
public final class VehicleEntity {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var make: String
    public var model: String
    public var year: Int
    public var mileageKm: Int
    /// Исходная строка `kind`, если сервер прислал вид, которого клиент не знает (`kindRaw` тогда `"car"`, как в домене).
    /// Уходит на сервер без изменений, пока пользователь явно не выбрал вид (`VehicleKindChange.set`).
    /// Необязательная колонка: лёгкая миграция добавляет её к существующим хранилищам.
    public var rawKind: String?
    @Relationship(deleteRule: .cascade, inverse: \ServiceRecordEntity.vehicle)
    public var serviceRecords: [ServiceRecordEntity] = []
    @Relationship(deleteRule: .cascade, inverse: \MaintenanceRuleEntity.vehicle)
    public var maintenanceRules: [MaintenanceRuleEntity] = []

    init(
        id: UUID,
        kindRaw: String,
        make: String,
        model: String,
        year: Int,
        mileageKm: Int
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.make = make
        self.model = model
        self.year = year
        self.mileageKm = mileageKm
    }

    /// Что синхронизация хранит рядом с доменной машиной.
    var syncExtras: VehicleSyncExtras {
        VehicleSyncExtras(rawKind: rawKind)
    }
}
