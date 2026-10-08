import Foundation

/// Единица интервала по времени в форме правила.
public enum PeriodUnit: Hashable, Sendable, CaseIterable {
    case days
    case months
}

/// Редактируемое состояние формы правила. Поля хранят сырой ввод; `makeRule(id:vehicleID:)` проверяет всё сразу.
public struct MaintenanceRuleDraft: Hashable, Sendable {
    public var serviceTypeChoice: ServiceTypeChoice
    public var otherServiceTypeText: String
    public var usesPeriod: Bool
    public var periodValueText: String
    public var periodUnit: PeriodUnit
    public var usesDistance: Bool
    public var distanceText: String
    /// «Последнее ТО было»: от этой даты и пробега считается срок, пока записей этого типа нет.
    public var startDate: Date
    public var startMileageText: String

    public init(
        serviceTypeChoice: ServiceTypeChoice = .oilChange,
        otherServiceTypeText: String = "",
        usesPeriod: Bool = true,
        periodValueText: String = "",
        periodUnit: PeriodUnit = .months,
        usesDistance: Bool = false,
        distanceText: String = "",
        startDate: Date = Date(),
        startMileageText: String = ""
    ) {
        self.serviceTypeChoice = serviceTypeChoice
        self.otherServiceTypeText = otherServiceTypeText
        self.usesPeriod = usesPeriod
        self.periodValueText = periodValueText
        self.periodUnit = periodUnit
        self.usesDistance = usesDistance
        self.distanceText = distanceText
        self.startDate = startDate
        self.startMileageText = startMileageText
    }

    /// Черновик для правки существующего правила: обратное отображение `makeRule`.
    public init(rule: MaintenanceRule) {
        var otherText = ""
        if case .other(let text) = rule.serviceType { otherText = text }
        var unit = PeriodUnit.months
        if case .days = rule.period { unit = .days }
        self.init(
            serviceTypeChoice: ServiceTypeChoice(rule.serviceType),
            otherServiceTypeText: otherText,
            usesPeriod: rule.period != nil,
            periodValueText: rule.period.map { String($0.value) } ?? "",
            periodUnit: unit,
            usesDistance: rule.distanceKm != nil,
            distanceText: rule.distanceKm.map(String.init) ?? "",
            startDate: rule.start.date,
            startMileageText: String(rule.start.mileageKm))
    }

    /// Поле формы, у которого может быть ошибка.
    public enum Field: Hashable, Sendable {
        case otherServiceType
        /// Не выбран ни один интервал.
        case interval
        case period
        case distance
        case startMileage
    }

    public typealias FieldError = ServiceRecordDraft.FieldError

    /// Все найденные проблемы черновика по полям.
    public struct Errors: Error, Equatable, Sendable {
        public var fields: [Field: FieldError]
    }

    /// Проверяет черновик целиком и собирает правило.
    /// - Parameter id: при правке — `id` исходного правила, для нового каждый вызов создаёт новый `UUID`.
    public func makeRule(id: MaintenanceRule.ID = UUID(), vehicleID: Vehicle.ID) throws(Errors) -> MaintenanceRule {
        var errors: [Field: FieldError] = [:]

        let serviceType = serviceTypeChoice.serviceType(otherText: otherServiceTypeText)
        if serviceType == nil { errors[.otherServiceType] = .required }

        if !usesPeriod && !usesDistance { errors[.interval] = .invalid(.noInterval) }

        var period: ServicePeriod?
        if usesPeriod {
            switch ServiceRecordDraft.parseInteger(periodValueText) {
            case .failure(let error): errors[.period] = error
            case .success(let value):
                let candidate: ServicePeriod = periodUnit == .days ? .days(value) : .months(value)
                do {
                    try candidate.validate()
                    period = candidate
                } catch {
                    errors[.period] = .invalid(error)
                }
            }
        }

        var distanceKm: Int?
        if usesDistance {
            switch ServiceRecordDraft.parseInteger(distanceText) {
            case .failure(let error): errors[.distance] = error
            case .success(let value):
                do {
                    try MaintenanceRule.validate(distanceKm: value)
                    distanceKm = value
                } catch {
                    errors[.distance] = .invalid(error)
                }
            }
        }

        var startMileage: Int?
        switch ServiceRecordDraft.parseMileage(startMileageText) {
        case .success(let value): startMileage = value
        case .failure(let error): errors[.startMileage] = error
        }

        guard errors.isEmpty, let serviceType, let startMileage else { throw Errors(fields: errors) }
        do {
            return try MaintenanceRule(
                id: id, vehicleID: vehicleID, serviceType: serviceType, period: period, distanceKm: distanceKm,
                start: MaintenanceStart(date: startDate, mileageKm: startMileage))
        } catch {
            // Недостижимо, пока проверки выше повторяют инварианты модели.
            throw Errors(fields: [.interval: .invalid(error)])
        }
    }
}
