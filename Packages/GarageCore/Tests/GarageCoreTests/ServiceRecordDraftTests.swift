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
