import Foundation
import Testing

@testable import GarageCore

// MARK: ServicePeriod

@Test func servicePeriodJSONIsStable() throws {
    #expect(try encodedString([ServicePeriod.days(30), .months(12)]) == #"["days:30","months:12"]"#)
}

@Test func servicePeriodRoundTripsAndChecksBounds() throws {
    #expect(
        try roundTrip([ServicePeriod.days(1), .days(3650), .months(1), .months(120)]) == [
            .days(1), .days(3650), .months(1), .months(120),
        ])
    #expect(throws: DecodingError.self) { try decode([ServicePeriod].self, from: #"["days:0"]"#) }
    #expect(throws: DecodingError.self) { try decode([ServicePeriod].self, from: #"["months:121"]"#) }
    #expect(throws: DecodingError.self) { try decode([ServicePeriod].self, from: #"["weeks:2"]"#) }
    #expect(throws: DecodingError.self) { try decode([ServicePeriod].self, from: #"["days:x"]"#) }
}

@Test func servicePeriodStorageStringReportsWhatIsWrong() {
    #expect(throws: ValidationError.unknownPeriod("weeks:2")) { try ServicePeriod(storageString: "weeks:2") }
    #expect(throws: ValidationError.periodOutOfRange(3651)) { try ServicePeriod(storageString: "days:3651") }
}

/// Незнакомая запись должна оставаться «незнакомой» (и уходить на сервер сырой), а не нормализоваться.
@Test(arguments: ["days:+5", "days:007", "months:012", "days:", "days: 5", "days:5 "])
func servicePeriodRejectsNonCanonicalNumbers(string: String) {
    #expect(throws: ValidationError.unknownPeriod(string)) { try ServicePeriod(storageString: string) }
}

// MARK: Invariants

@Test func ruleNeedsAtLeastOneInterval() {
    #expect(throws: ValidationError.noInterval) { try makeRule(period: nil, distanceKm: nil) }
    #expect(throws: Never.self) { try makeRule(period: nil, distanceKm: 5_000) }
    #expect(throws: Never.self) { try makeRule(period: .days(7), distanceKm: nil) }
}

@Test func ruleChecksPeriodBounds() {
    for (period, bad) in [
        (ServicePeriod.days(0), 0), (.days(-1), -1), (.days(3651), 3651), (.months(0), 0), (.months(121), 121),
    ] {
        #expect(throws: ValidationError.periodOutOfRange(bad)) { try makeRule(period: period) }
    }
    for period in [ServicePeriod.days(1), .days(3650), .months(1), .months(120)] {
        #expect(throws: Never.self) { try makeRule(period: period) }
    }
}

@Test func ruleChecksDistanceBounds() {
    for bad in [0, -5, ServiceRecord.maxMileageKm + 1] {
        #expect(throws: ValidationError.distanceOutOfRange(bad)) { try makeRule(period: nil, distanceKm: bad) }
    }
    for good in [1, ServiceRecord.maxMileageKm] {
        #expect(throws: Never.self) { try makeRule(period: nil, distanceKm: good) }
    }
}

@Test func ruleRejectsBlankOtherServiceType() {
    #expect(throws: ValidationError.emptyServiceTypeDescription) { try makeRule(serviceType: .other("  \n")) }
    #expect(throws: Never.self) { try makeRule(serviceType: .other("Антифриз")) }
}

@Test func ruleChecksStartMileage() {
    #expect(throws: ValidationError.negativeMileage(-1)) { try makeRule(startMileageKm: -1) }
    #expect(throws: ValidationError.mileageTooLarge(ServiceRecord.maxMileageKm + 1)) {
        try makeRule(startMileageKm: ServiceRecord.maxMileageKm + 1)
    }
}

// MARK: update…

@Test func updatesCheckTheSameInvariants() throws {
    var rule = try makeRule(period: .months(12), distanceKm: 10_000)

    #expect(throws: ValidationError.emptyServiceTypeDescription) { try rule.updateServiceType(.other(" ")) }
    #expect(rule.serviceType == .oilChange)

    #expect(throws: ValidationError.noInterval) { try rule.updateInterval(period: nil, distanceKm: nil) }
    #expect(throws: ValidationError.periodOutOfRange(0)) { try rule.updateInterval(period: .days(0), distanceKm: 1) }
    #expect(throws: ValidationError.distanceOutOfRange(0)) { try rule.updateInterval(period: nil, distanceKm: 0) }
    #expect(rule.period == .months(12) && rule.distanceKm == 10_000)

    try rule.updateServiceType(.brakes)
    try rule.updateInterval(period: nil, distanceKm: 50_000)
    #expect(rule.serviceType == .brakes && rule.period == nil && rule.distanceKm == 50_000)
}

// MARK: Codable

private let ruleJSON =
    #"{"distanceKm":10000,"id":"22222222-2222-4222-8222-222222222222","period":"months:12","serviceType":"oilChange","start":{"date":"2026-10-08T00:00:00Z","mileageKm":87400},"vehicleID":"11111111-1111-4111-8111-111111111111"}"#

private func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func jsonDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

@Test func ruleJSONIsStable() throws {
    let rule = try makeRule(
        id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, period: .months(12), distanceKm: 10_000,
        startDate: isoDate("2026-10-08T00:00:00Z"), startMileageKm: 87_400)
    #expect(String(decoding: try jsonEncoder().encode(rule), as: UTF8.self) == ruleJSON)
    #expect(try jsonDecoder().decode(MaintenanceRule.self, from: Data(ruleJSON.utf8)) == rule)
}

@Test func ruleWithoutPeriodOmitsTheKey() throws {
    let rule = try makeRule(period: nil, distanceKm: 5_000)
    let text = String(decoding: try jsonEncoder().encode(rule), as: UTF8.self)
    #expect(!text.contains("period"))
    #expect(try jsonDecoder().decode(MaintenanceRule.self, from: Data(text.utf8)) == rule)
}

@Test func decodingGoesThroughTheInitializer() {
    let noInterval = ruleJSON.replacingOccurrences(of: #""distanceKm":10000,"#, with: "")
        .replacingOccurrences(of: #""period":"months:12","#, with: "")
    let badDistance = ruleJSON.replacingOccurrences(of: "10000", with: "0")
    let badStart = ruleJSON.replacingOccurrences(of: "87400", with: "-1")
    // Как у `ServiceRecord`: ошибка инварианта пробрасывается как `ValidationError`.
    let expected: [ValidationError] = [.noInterval, .distanceOutOfRange(0), .negativeMileage(-1)]
    for (broken, error) in zip([noInterval, badDistance, badStart], expected) {
        #expect(throws: error, "\(broken)") {
            try jsonDecoder().decode(MaintenanceRule.self, from: Data(broken.utf8))
        }
    }
}
