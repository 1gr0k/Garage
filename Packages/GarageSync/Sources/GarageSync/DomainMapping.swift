import Foundation
import GarageAPI
import GarageCore

/// Что сервер знает о машине, а домен — нет (решение 9a, T7). Адаптер хранилища держит поле рядом с машиной и
/// отдаёт обратно при push, поэтому локальная правка его не стирает.
public struct VehicleSyncExtras: Hashable, Sendable {
    /// Исходная строка `kind`, если сервер прислал вид, которого клиент не знает (в домене он читается как `.car`).
    /// Уходит обратно, пока пользователь не выбрал вид явно: адаптер сбрасывает поле только по `VehicleKindChange.set`
    /// (сравнить `vehicle.kind` с сырым значением нельзя, решение 9e).
    public var rawKind: String?

    public init(rawKind: String? = nil) {
        self.rawKind = rawKind
    }
}

/// What the server knows about a record but the domain model does not. The storage adapter keeps both
/// fields next to the record and hands them back on push, so a local edit never erases them.
public struct RecordSyncExtras: Hashable, Sendable {
    /// Receipt photo reference; the blob itself travels through `ReceiptBlobStore`.
    public var receipt: ReceiptRefDTO?
    /// The original `serviceType` string when the server sent a value this client does not know.
    public var rawServiceType: String?

    public init(receipt: ReceiptRefDTO? = nil, rawServiceType: String? = nil) {
        self.receipt = receipt
        self.rawServiceType = rawServiceType
    }
}

/// Что сервер знает о правиле, а домен — нет (решение 9a, T9). Адаптер хранилища держит оба поля рядом с правилом
/// и отдаёт обратно при push, поэтому локальная правка их не стирает.
public struct RuleSyncExtras: Hashable, Sendable {
    /// Исходная строка `serviceType`, если сервер прислал незнакомое значение.
    public var rawServiceType: String?
    /// Исходная строка `period` (например `"weeks:2"`), если клиент её не понимает: в домене `period == nil`.
    /// Уходит обратно, пока у правила нет известного интервала по времени. Адаптер хранилища сбрасывает поле только
    /// когда пользователь явно задал или убрал интервал по времени; правка пробега или типа его не трогает.
    /// Явное состояние формы для этого — открытый вопрос части B (аналог решения 9e для вида машины).
    public var rawPeriod: String?

    public init(rawServiceType: String? = nil, rawPeriod: String? = nil) {
        self.rawServiceType = rawServiceType
        self.rawPeriod = rawPeriod
    }
}

extension Vehicle {
    /// Маппинг DTO в домен. Незнакомый `kind` читается как `.car`, исходная строка остаётся в `extras`
    /// (раньше такая машина пропускалась, а вместе с ней и все её записи: `cannotApply` без машины).
    public static func decoded(from dto: VehicleDTO) throws -> (vehicle: Vehicle, extras: VehicleSyncExtras) {
        var extras = VehicleSyncExtras()
        let kind: VehicleKind
        if let known = VehicleKind(rawValue: dto.kind) {
            kind = known
        } else {
            kind = .car
            extras.rawKind = dto.kind
        }
        let vehicle = try Vehicle(
            id: dto.id, kind: kind, make: dto.make, model: dto.model, year: dto.year, mileageKm: dto.mileageKm)
        return (vehicle, extras)
    }
}

extension VehicleDTO {
    public init(_ vehicle: Vehicle, extras: VehicleSyncExtras = VehicleSyncExtras()) {
        // Сырая строка уходит, пока она есть: хранилище сбрасывает её только явным выбором вида (`VehicleKindChange.set`).
        self.init(
            id: vehicle.id, kind: extras.rawKind ?? vehicle.kind.rawValue, make: vehicle.make, model: vehicle.model,
            year: vehicle.year, mileageKm: vehicle.mileageKm)
    }
}

extension Part {
    public init(dto: PartDTO) throws {
        try self.init(
            id: dto.id, name: dto.name, partNumber: dto.partNumber,
            unitPrice: Money(kopecks: dto.unitPriceKopecks), quantity: dto.quantity)
    }
}

extension PartDTO {
    public init(_ part: Part) {
        self.init(
            id: part.id, name: part.name, partNumber: part.partNumber,
            unitPriceKopecks: part.unitPrice.kopecks, quantity: part.quantity)
    }
}

extension ServiceRecord {
    /// Maps a DTO to the domain. A `serviceType` this client does not know is read as `.other(<string>)`
    /// and the original string is kept in the extras (see `docs/api.md`, "Версионирование").
    public static func decoded(from dto: ServiceRecordDTO) throws -> (record: ServiceRecord, extras: RecordSyncExtras) {
        var extras = RecordSyncExtras(receipt: dto.receipt)
        let serviceType: ServiceType
        do {
            serviceType = try ServiceType(storageString: dto.serviceType)
        } catch {
            serviceType = .other(dto.serviceType)
            extras.rawServiceType = dto.serviceType
        }
        let record = try ServiceRecord(
            id: dto.id, vehicleID: dto.vehicleID, date: dto.date, mileageKm: dto.mileageKm,
            serviceType: serviceType, laborCost: Money(kopecks: dto.laborCostKopecks), notes: dto.notes,
            parts: dto.parts.map(Part.init(dto:)))
        return (record, extras)
    }
}

extension MaintenanceRule {
    /// Маппинг DTO в домен. Незнакомые `serviceType` и `period` читаются терпимо: первый — как `.other(<строка>)`,
    /// второй — как отсутствие интервала по времени; оригиналы остаются в `extras`. Если после этого не остаётся ни
    /// одного интервала, бросает `ValidationError.noInterval`: движок пропустит правило (`skipped`).
    public static func decoded(from dto: MaintenanceRuleDTO) throws -> (rule: MaintenanceRule, extras: RuleSyncExtras) {
        var extras = RuleSyncExtras()
        let serviceType: ServiceType
        do {
            serviceType = try ServiceType(storageString: dto.serviceType)
        } catch {
            serviceType = .other(dto.serviceType)
            extras.rawServiceType = dto.serviceType
        }
        var period: ServicePeriod?
        if let raw = dto.period {
            do {
                period = try ServicePeriod(storageString: raw)
            } catch .unknownPeriod {
                extras.rawPeriod = raw
            }
            // Известный формат с выходом за границы — нарушение формата, а не эволюция: пробрасывается и пропускает правило.
        }
        let rule = try MaintenanceRule(
            id: dto.id, vehicleID: dto.vehicleID, serviceType: serviceType, period: period,
            distanceKm: dto.distanceKm, start: MaintenanceStart(date: dto.startDate, mileageKm: dto.startMileageKm))
        return (rule, extras)
    }
}

extension MaintenanceRuleDTO {
    public init(_ rule: MaintenanceRule, extras: RuleSyncExtras) {
        // Сырая строка уходит, только пока тип остался тем незнакомым значением, которым был прочитан
        // (как у записи); пользовательская смена типа определяется сравнением.
        let serviceType: String
        if let raw = extras.rawServiceType, rule.serviceType == .other(raw) {
            serviceType = raw
        } else {
            serviceType = rule.serviceType.storageString
        }
        self.init(
            id: rule.id, vehicleID: rule.vehicleID, serviceType: serviceType,
            period: rule.period?.storageString ?? extras.rawPeriod, distanceKm: rule.distanceKm,
            startDate: rule.start.date, startMileageKm: rule.start.mileageKm)
    }
}

extension ServiceRecordDTO {
    public init(_ record: ServiceRecord, extras: RecordSyncExtras) {
        // The raw string is sent only while the type is still the unknown value it was read as;
        // a user's change of type is detected by comparison, not by clearing the extras on edit.
        let serviceType: String
        if let raw = extras.rawServiceType, record.serviceType == .other(raw) {
            serviceType = raw
        } else {
            serviceType = record.serviceType.storageString
        }
        self.init(
            id: record.id, vehicleID: record.vehicleID, date: record.date, mileageKm: record.mileageKm,
            serviceType: serviceType, laborCostKopecks: record.laborCost.kopecks, notes: record.notes,
            parts: record.parts.map(PartDTO.init(_:)), receipt: extras.receipt)
    }
}
