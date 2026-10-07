import Foundation
import Testing

@testable import GarageCore

private func fieldErrors(_ draft: ServiceRecordDraft) -> [ServiceRecordDraft.Field: ServiceRecordDraft.FieldError] {
    do {
        _ = try draft.makeRecord(vehicleID: UUID())
        return [:]
    } catch {
        return error.fields
    }
}

@Test(arguments: ["9999", "1"])
func draftAcceptsBoundaryPartQuantity(quantity: String) throws {
    let part = PartDraft(name: "Болт", unitPriceText: "1", quantityText: quantity)
    let draft = ServiceRecordDraft(mileageText: "1000", parts: [part])

    #expect(fieldErrors(draft) == [:])
}

@Test(arguments: [("10000", 10_000), ("9223372036854775807", Int.max)])
func draftRejectsTooLargePartQuantity(text: String, value: Int) {
    let part = PartDraft(name: "Болт", unitPriceText: "1", quantityText: text)
    let draft = ServiceRecordDraft(mileageText: "1000", parts: [part])

    #expect(fieldErrors(draft) == [.partQuantity(part.id): .invalid(.quantityTooLarge(value))])
}

@Test func draftEnforcesAmountLimitOnPriceAndLaborCost() {
    let atLimit = PartDraft(name: "Болт", unitPriceText: "10 000 000")
    let above = PartDraft(name: "Гайка", unitPriceText: "10 000 000,01")
    let draft = ServiceRecordDraft(mileageText: "1000", laborCostText: "10000000.01", parts: [atLimit, above])
    let tooMuch = Money(kopecks: Money.maxAmount.kopecks + 1)

    #expect(
        fieldErrors(draft) == [
            .laborCost: .invalid(.amountTooLarge(tooMuch)),
            .partUnitPrice(above.id): .invalid(.amountTooLarge(tooMuch)),
        ])
    #expect(fieldErrors(ServiceRecordDraft(mileageText: "1", laborCostText: "10000000")) == [:])
}

@Test(arguments: ["87 400", "87\u{00A0}400", "87\u{202F}400", " 87400 "])
func mileageParsingIgnoresAllWhitespace(text: String) throws {
    #expect(try ServiceRecordDraft.parseMileage(text).get() == 87_400)
    let record = try ServiceRecordDraft(mileageText: text).makeRecord(vehicleID: UUID())
    #expect(record.mileageKm == 87_400)
}

@Test func mileageParsingReportsErrors() {
    #expect(ServiceRecordDraft.parseMileage("  ") == .failure(.required))
    #expect(ServiceRecordDraft.parseMileage("12k") == .failure(.notANumber))
    #expect(ServiceRecordDraft.parseMileage("-5") == .failure(.invalid(.negativeMileage(-5))))
}

@Test func emptyDraftReportsOnlyRequiredMileage() {
    #expect(fieldErrors(ServiceRecordDraft()) == [.mileage: .required])
}

@Test func draftCollectsAllErrorsAtOnce() {
    let part = PartDraft(name: " ", unitPriceText: "abc", quantityText: "0")
    let draft = ServiceRecordDraft(
        mileageText: "12k",
        serviceTypeChoice: .other,
        otherServiceTypeText: "  ",
        laborCostText: "1,234",
        parts: [part]
    )

    #expect(
        fieldErrors(draft) == [
            .mileage: .notANumber,
            .otherServiceType: .required,
            .laborCost: .notANumber,
            .partName(part.id): .required,
            .partUnitPrice(part.id): .notANumber,
            .partQuantity(part.id): .invalid(.nonPositiveQuantity(0)),
        ])
}

@Test func partErrorsAreBoundToTheirPartID() {
    let good = PartDraft(name: "Фильтр", unitPriceText: "500")
    let bad = PartDraft(name: "Масло", unitPriceText: "", quantityText: "x")
    let draft = ServiceRecordDraft(mileageText: "1000", parts: [good, bad])

    #expect(fieldErrors(draft) == [.partUnitPrice(bad.id): .required, .partQuantity(bad.id): .notANumber])
}

@Test func negativeMileageIsInvalid() {
    #expect(fieldErrors(ServiceRecordDraft(mileageText: "-5")) == [.mileage: .invalid(.negativeMileage(-5))])
}

@Test func emptyLaborCostMeansZeroAndEmptyPartNumberIsNil() throws {
    let part = PartDraft(name: "Свеча", partNumber: "  ", unitPriceText: "650,50", quantityText: "4")
    let draft = ServiceRecordDraft(mileageText: "87000", parts: [part])
    let vehicleID = UUID()

    let record = try draft.makeRecord(vehicleID: vehicleID)

    #expect(record.laborCost == .zero)
    #expect(record.mileageKm == 87_000)
    #expect(record.vehicleID == vehicleID)
    #expect(record.parts.first?.partNumber == nil)
    #expect(record.parts.first?.id == part.id)
    #expect(record.totalCost == Money(rubles: 2_602))
}

@Test func successfulDraftBuildsRecord() throws {
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let draft = ServiceRecordDraft(
        date: date,
        mileageText: "87400",
        serviceTypeChoice: .other,
        otherServiceTypeText: " Мойка ",
        laborCostText: "1\u{00A0}500",
        parts: [PartDraft(name: "Шампунь", partNumber: "SH-1", unitPriceText: "300")],
        notes: "Заметка"
    )

    let record = try draft.makeRecord(vehicleID: UUID())

    #expect(record.date == date)
    #expect(record.serviceType == .other("Мойка"))
    #expect(record.laborCost == Money(rubles: 1_500))
    #expect(record.notes == "Заметка")
    #expect(record.parts.first?.partNumber == "SH-1")
}

@Test func everyChoiceMapsToItsServiceType() throws {
    let expected: [ServiceTypeChoice: ServiceType] = [
        .oilChange: .oilChange, .filters: .filters, .tires: .tires, .brakes: .brakes, .chain: .chain,
        .suspension: .suspension, .inspection: .inspection, .repair: .repair,
    ]
    for choice in ServiceTypeChoice.allCases where choice != .other {
        let draft = ServiceRecordDraft(mileageText: "1", serviceTypeChoice: choice)
        #expect(try draft.makeRecord(vehicleID: UUID()).serviceType == expected[choice])
    }
}

@Test(arguments: ["10000000", "10 000 000"])
func draftAcceptsMaximumMileage(text: String) {
    #expect(fieldErrors(ServiceRecordDraft(mileageText: text)) == [:])
}

@Test(arguments: [("10000001", 10_000_001), ("9223372036854775807", Int.max)])
func draftRejectsTooLargeMileage(text: String, value: Int) {
    #expect(fieldErrors(ServiceRecordDraft(mileageText: text)) == [.mileage: .invalid(.mileageTooLarge(value))])
}

@Test(arguments: ["1 ", "\u{00A0}1\u{00A0}", "1\u{202F}", "1 000"])
func partQuantityIgnoresAllWhitespace(text: String) {
    let part = PartDraft(name: "Болт", unitPriceText: "1", quantityText: text)
    let draft = ServiceRecordDraft(mileageText: "1000", parts: [part])

    #expect(fieldErrors(draft) == [:])
}

// MARK: Черновик из записи

private let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)

private func sampleRecords() throws -> [ServiceRecord] {
    let vehicleID = Vehicle.SampleID.landCruiser
    return [
        try ServiceRecord(
            vehicleID: vehicleID, date: sampleDate, mileageKm: 87_400, serviceType: .oilChange,
            laborCost: Money(rubles: 1_250, kopecks: 50), notes: "Масло 5W-30",
            parts: [
                try Part(name: "Фильтр", partNumber: "04152-YZZA1", unitPrice: Money(rubles: 700), quantity: 1),
                try Part(name: "Масло", unitPrice: Money(rubles: 1_999, kopecks: 5), quantity: 6),
            ]),
        try ServiceRecord(
            vehicleID: vehicleID, date: sampleDate, mileageKm: 0, serviceType: .other("Мойка двигателя"),
            laborCost: .zero),
        try ServiceRecord(
            vehicleID: vehicleID, date: sampleDate, mileageKm: 10_000_000, serviceType: .tires,
            laborCost: Money(kopecks: 1)),
    ]
}

@Test func draftFromRecordRoundTrips() throws {
    for record in try sampleRecords() {
        let rebuilt = try ServiceRecordDraft(record: record).makeRecord(id: record.id, vehicleID: record.vehicleID)
        #expect(rebuilt == record)
    }
}

@Test(arguments: [(".", "1250.50"), (",", "1250,50")] as [(Character, String)])
func draftFromRecordUsesDecimalSeparator(separator: Character, expected: String) throws {
    let record = try sampleRecords()[0]
    let draft = ServiceRecordDraft(record: record, decimalSeparator: separator)

    #expect(draft.laborCostText == expected)
    #expect(try draft.makeRecord(id: record.id, vehicleID: record.vehicleID) == record)
}

@Test func draftFromRecordFillsFields() throws {
    let records = try sampleRecords()
    let draft = ServiceRecordDraft(record: records[0])

    #expect(draft.mileageText == "87400")
    #expect(draft.serviceTypeChoice == .oilChange)
    #expect(draft.otherServiceTypeText == "")
    #expect(draft.notes == "Масло 5W-30")
    #expect(draft.parts.map(\.id) == records[0].parts.map(\.id))
    #expect(draft.parts[0].partNumber == "04152-YZZA1")
    #expect(draft.parts[1].partNumber == "")
    #expect(draft.parts[1].unitPriceText == "1999.05")
    #expect(draft.parts[1].quantityText == "6")
}

@Test func draftFromRecordWithZeroLaborAndOtherType() throws {
    let draft = ServiceRecordDraft(record: try sampleRecords()[1])

    #expect(draft.laborCostText == "")
    #expect(draft.serviceTypeChoice == .other)
    #expect(draft.otherServiceTypeText == "Мойка двигателя")
}

@Test func makeRecordKeepsGivenIDAndGeneratesNewOtherwise() throws {
    let draft = ServiceRecordDraft(mileageText: "1000")
    let vehicleID = UUID()
    let id = UUID()

    #expect(try draft.makeRecord(id: id, vehicleID: vehicleID).id == id)
    #expect(try draft.makeRecord(vehicleID: vehicleID).id != draft.makeRecord(vehicleID: vehicleID).id)
}
