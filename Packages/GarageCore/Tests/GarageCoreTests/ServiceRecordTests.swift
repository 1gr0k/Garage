import Foundation
import Testing

@testable import GarageCore

private func makeRecord(parts: [Part]) throws -> ServiceRecord {
    try ServiceRecord(
        vehicleID: Vehicle.samples[0].id,
        date: Date(timeIntervalSinceReferenceDate: 800_000_000),
        mileageKm: 87_000,
        serviceType: .oilChange,
        laborCost: Money(rubles: 1_500),
        notes: "Масло 5W-30",
        parts: parts
    )
}

@Test func totalCostAddsLaborAndParts() throws {
    let record = try makeRecord(parts: [
        Part(name: "Масло", unitPrice: Money(rubles: 890, kopecks: 90), quantity: 5),
        Part(name: "Масляный фильтр", partNumber: "90915-YZZD4", unitPrice: Money(rubles: 1_200)),
    ])

    #expect(record.partsCost == Money(rubles: 5_654, kopecks: 50))
    #expect(record.totalCost == Money(rubles: 7_154, kopecks: 50))
}

@Test func recordWithoutPartsCostsOnlyLabor() throws {
    let record = try makeRecord(parts: [])

    #expect(record.partsCost == .zero)
    #expect(record.totalCost == Money(rubles: 1_500))
}

@Test func recordRejectsNegativeMileage() {
    #expect(throws: ValidationError.negativeMileage(-10)) {
        try ServiceRecord(
            vehicleID: UUID(),
            date: .now,
            mileageKm: -10,
            serviceType: .other("Мойка"),
            laborCost: .zero
        )
    }
}

@Test func recordRoundTripsThroughJSON() throws {
    var record = try makeRecord(parts: [
        Part(name: "Масляный фильтр", partNumber: "90915-YZZD4", unitPrice: Money(rubles: 1_200))
    ])
    try record.updateServiceType(.other("Замена свечей"))

    #expect(try roundTrip(record) == record)
}

@Test func decodingRecordValidatesNestedParts() throws {
    let record = try makeRecord(parts: [Part(name: "Фильтр", unitPrice: Money(rubles: 500), quantity: 2)])
    let json = try encodedString(record).replacingOccurrences(of: #""quantity":2"#, with: #""quantity":-1"#)

    #expect(throws: ValidationError.nonPositiveQuantity(-1)) {
        try decode(ServiceRecord.self, from: json)
    }
}

@Test func updateRecordMileageValidatesAndKeepsOldValueOnFailure() throws {
    var record = try makeRecord(parts: [])

    try record.updateMileage(87_500)
    #expect(record.mileageKm == 87_500)

    #expect(throws: ValidationError.negativeMileage(-7)) {
        try record.updateMileage(-7)
    }
    #expect(record.mileageKm == 87_500)
}

@Test func recordRejectsNegativeLaborCost() {
    #expect(throws: ValidationError.negativeAmount(Money(kopecks: -1))) {
        try ServiceRecord(
            vehicleID: UUID(), date: Date(), mileageKm: 1, serviceType: .repair, laborCost: Money(kopecks: -1))
    }
}

@Test(arguments: ["", "  "])
func recordRejectsBlankOtherServiceType(text: String) {
    #expect(throws: ValidationError.emptyServiceTypeDescription) {
        try ServiceRecord(vehicleID: UUID(), date: Date(), mileageKm: 1, serviceType: .other(text), laborCost: .zero)
    }
}

@Test func recordUpdatesValidateAndKeepOldValueOnFailure() throws {
    var record = try makeRecord(parts: [])

    #expect(throws: ValidationError.emptyServiceTypeDescription) { try record.updateServiceType(.other(" ")) }
    #expect(throws: ValidationError.negativeAmount(Money(kopecks: -1))) {
        try record.updateLaborCost(Money(kopecks: -1))
    }
    #expect(record.serviceType == .oilChange)
    #expect(record.laborCost == Money(rubles: 1_500))
}

@Test func decodingRecordValidatesLaborCostAndServiceType() throws {
    let record = try makeRecord(parts: [])
    let json = try encodedString(record)

    let negative = json.replacingOccurrences(of: #""laborCost":150000"#, with: #""laborCost":-1"#)
    #expect(throws: ValidationError.negativeAmount(Money(kopecks: -1))) { try decode(ServiceRecord.self, from: negative) }

    let blank = json.replacingOccurrences(of: #""oilChange""#, with: #""other:  ""#)
    #expect(throws: ValidationError.emptyServiceTypeDescription) { try decode(ServiceRecord.self, from: blank) }
}

@Test func sequenceTotalCostSumsRecords() throws {
    let records = [
        try makeRecord(parts: [Part(name: "Фильтр", unitPrice: Money(rubles: 500), quantity: 2)]),
        try makeRecord(parts: []),
    ]

    #expect(records.totalCost == Money(rubles: 2_500 + 1_500))
    #expect([ServiceRecord]().totalCost == .zero)
}
