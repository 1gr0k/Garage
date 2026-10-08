import Foundation

@testable import GarageCore

/// Григорианский календарь с фиксированным часовым поясом (тесты не зависят от пояса машины).
func makeCalendar(_ timeZone: String = "Europe/Moscow") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    return calendar
}

/// Полдень указанного дня в календаре: далёк от границ суток и перехода на летнее время.
func noon(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar = makeCalendar()) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

func isoDate(_ string: String) -> Date {
    try! Date.ISO8601FormatStyle().parse(string)
}

let testVehicleID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
let otherVehicleID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

func makeRule(
    id: UUID = UUID(),
    vehicleID: UUID = testVehicleID,
    serviceType: ServiceType = .oilChange,
    period: ServicePeriod? = .months(12),
    distanceKm: Int? = nil,
    startDate: Date = noon(2026, 1, 10),
    startMileageKm: Int = 87_000
) throws -> MaintenanceRule {
    try MaintenanceRule(
        id: id, vehicleID: vehicleID, serviceType: serviceType, period: period, distanceKm: distanceKm,
        start: MaintenanceStart(date: startDate, mileageKm: startMileageKm))
}

func makeRecord(
    id: UUID = UUID(),
    vehicleID: UUID = testVehicleID,
    serviceType: ServiceType = .oilChange,
    date: Date,
    mileageKm: Int = 87_000
) throws -> ServiceRecord {
    try ServiceRecord(
        id: id, vehicleID: vehicleID, date: date, mileageKm: mileageKm, serviceType: serviceType,
        laborCost: .zero)
}

func makeVehicle(id: UUID = testVehicleID, mileageKm: Int = 87_000, make: String = "Toyota") throws -> Vehicle {
    try Vehicle(id: id, kind: .car, make: make, model: "Land Cruiser", year: 2019, mileageKm: mileageKm)
}
