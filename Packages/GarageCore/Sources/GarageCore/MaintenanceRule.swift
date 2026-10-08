import Foundation

/// Дата и пробег, от которых считается срок правила, пока нет ни одной записи этого типа.
public struct MaintenanceStart: Hashable, Sendable, Codable {
    public var date: Date
    /// Пробег в километрах; границы те же, что у `ServiceRecord`.
    public var mileageKm: Int

    public init(date: Date, mileageKm: Int) throws(ValidationError) {
        try ServiceRecord.validate(mileageKm: mileageKm)
        self.date = date
        self.mileageKm = mileageKm
    }

    private enum CodingKeys: String, CodingKey {
        case date, mileageKm
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            date: container.decode(Date.self, forKey: .date),
            mileageKm: container.decode(Int.self, forKey: .mileageKm))
    }
}

/// Правило обслуживания машины: тип работ и интервал по времени, по пробегу или оба («что раньше»).
/// Срок считает `MaintenanceSchedule`; само правило ничего не знает о записях.
public struct MaintenanceRule: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var vehicleID: Vehicle.ID
    public private(set) var serviceType: ServiceType
    public private(set) var period: ServicePeriod?
    /// Интервал по пробегу, км.
    public private(set) var distanceKm: Int?
    /// От чего считать, пока записей этого типа нет (решение 3 плана этапа 12).
    public private(set) var start: MaintenanceStart

    public init(
        id: UUID = UUID(),
        vehicleID: Vehicle.ID,
        serviceType: ServiceType,
        period: ServicePeriod?,
        distanceKm: Int?,
        start: MaintenanceStart
    ) throws(ValidationError) {
        try Self.validate(serviceType: serviceType)
        try Self.validate(period: period, distanceKm: distanceKm)
        self.id = id
        self.vehicleID = vehicleID
        self.serviceType = serviceType
        self.period = period
        self.distanceKm = distanceKm
        self.start = start
    }

    /// Меняет тип работ, соблюдая тот же инвариант, что `init`.
    public mutating func updateServiceType(_ serviceType: ServiceType) throws(ValidationError) {
        try Self.validate(serviceType: serviceType)
        self.serviceType = serviceType
    }

    /// Меняет оба интервала разом: «хотя бы один задан» относится к паре, а не к каждому по отдельности.
    public mutating func updateInterval(period: ServicePeriod?, distanceKm: Int?) throws(ValidationError) {
        try Self.validate(period: period, distanceKm: distanceKm)
        self.period = period
        self.distanceKm = distanceKm
    }

    public mutating func updateStart(_ start: MaintenanceStart) {
        self.start = start
    }

    /// Диапазон интервала по пробегу; `MaintenanceRuleDraft` использует его же, чтобы форма и модель совпадали.
    static func validate(distanceKm: Int) throws(ValidationError) {
        guard (1...ServiceRecord.maxMileageKm).contains(distanceKm) else { throw .distanceOutOfRange(distanceKm) }
    }

    private static func validate(serviceType: ServiceType) throws(ValidationError) {
        if case .other(let text) = serviceType,
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw .emptyServiceTypeDescription
        }
    }

    private static func validate(period: ServicePeriod?, distanceKm: Int?) throws(ValidationError) {
        guard period != nil || distanceKm != nil else { throw .noInterval }
        try period?.validate()
        if let distanceKm { try validate(distanceKm: distanceKm) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, vehicleID, serviceType, period, distanceKm, start
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            vehicleID: container.decode(UUID.self, forKey: .vehicleID),
            serviceType: container.decode(ServiceType.self, forKey: .serviceType),
            period: container.decodeIfPresent(ServicePeriod.self, forKey: .period),
            distanceKm: container.decodeIfPresent(Int.self, forKey: .distanceKm),
            start: container.decode(MaintenanceStart.self, forKey: .start))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(vehicleID, forKey: .vehicleID)
        try container.encode(serviceType, forKey: .serviceType)
        try container.encodeIfPresent(period, forKey: .period)
        try container.encodeIfPresent(distanceKm, forKey: .distanceKm)
        try container.encode(start, forKey: .start)
    }
}
