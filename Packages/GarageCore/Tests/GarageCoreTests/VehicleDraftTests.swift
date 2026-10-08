import Foundation
import Testing

@testable import GarageCore

private let currentYear = 2026

private func vehicleFieldErrors(_ draft: VehicleDraft) -> [VehicleDraft.Field: VehicleDraft.FieldError] {
    do {
        _ = try draft.makeVehicle(currentYear: currentYear)
        return [:]
    } catch {
        return error.fields
    }
}

private func validDraft() -> VehicleDraft {
    VehicleDraft(kind: .car, make: "Lada", model: "Niva", yearText: "2020", mileageText: "1000")
}

@Test func vehicleDraftRoundTripsSamples() throws {
    for vehicle in Vehicle.samples {
        let rebuilt = try VehicleDraft(vehicle: vehicle).makeVehicle(id: vehicle.id, currentYear: currentYear)
        #expect(rebuilt == vehicle)
    }
}

@Test func vehicleDraftFromVehicleFillsFieldsWithPlainDigits() {
    let draft = VehicleDraft(vehicle: Vehicle.samples[1])

    #expect(draft.kind == .car)
    #expect(draft.make == "Volkswagen")
    #expect(draft.model == "Transporter")
    #expect(draft.yearText == "2015")
    #expect(draft.mileageText == "214000")
}

@Test func vehicleDraftOfUnrecognizedKindHasNoChosenKindAndStillBuildsACar() throws {
    let vehicle = Vehicle.samples[2]
    let draft = VehicleDraft(vehicle: vehicle, unrecognizedKind: "tractor")

    #expect(draft.kind == nil)
    #expect(draft.unrecognizedKind == "tractor")
    #expect(try draft.makeVehicle(id: vehicle.id, currentYear: currentYear).kind == .car)
}

@Test func vehicleDraftWithoutKindAndWithoutUnrecognizedKindRequiresIt() {
    var draft = validDraft()
    draft.kind = nil

    #expect(vehicleFieldErrors(draft) == [.kind: .required])
}

@Test(arguments: ["", "  ", "\u{00A0}"])
func vehicleDraftRequiresMakeAndModel(text: String) {
    var draft = validDraft()
    draft.make = text
    draft.model = text

    #expect(vehicleFieldErrors(draft) == [.make: .required, .model: .required])
}

@Test func vehicleDraftTrimsMakeAndModel() throws {
    var draft = validDraft()
    draft.make = "  Toyota "
    draft.model = " Land Cruiser  "

    let vehicle = try draft.makeVehicle(currentYear: currentYear)

    #expect(vehicle.make == "Toyota")
    #expect(vehicle.model == "Land Cruiser")
}

@Test func vehicleDraftReportsYearErrors() {
    var draft = validDraft()
    let allowed = 1900...(currentYear + 1)

    draft.yearText = ""
    #expect(vehicleFieldErrors(draft) == [.year: .required])
    draft.yearText = "abc"
    #expect(vehicleFieldErrors(draft) == [.year: .notANumber])
    draft.yearText = "1899"
    #expect(vehicleFieldErrors(draft) == [.year: .yearOutOfRange(allowed)])
    draft.yearText = String(currentYear + 2)
    #expect(vehicleFieldErrors(draft) == [.year: .yearOutOfRange(allowed)])
}

@Test(arguments: ["1900", "2027", " 2027 "])
func vehicleDraftAcceptsBoundaryYears(text: String) {
    var draft = validDraft()
    draft.yearText = text

    #expect(vehicleFieldErrors(draft) == [:])
}

@Test func vehicleDraftReportsMileageErrors() {
    var draft = validDraft()

    draft.mileageText = "-5"
    #expect(vehicleFieldErrors(draft) == [.mileage: .invalid(.negativeMileage(-5))])
    draft.mileageText = " "
    #expect(vehicleFieldErrors(draft) == [.mileage: .required])
    draft.mileageText = "12k"
    #expect(vehicleFieldErrors(draft) == [.mileage: .notANumber])
    draft.mileageText = "10000001"
    #expect(vehicleFieldErrors(draft) == [.mileage: .invalid(.mileageTooLarge(10_000_001))])
}

@Test func vehicleDraftParsesMileageWithSeparators() throws {
    var draft = validDraft()
    draft.mileageText = "87\u{00A0}400"

    #expect(try draft.makeVehicle(currentYear: currentYear).mileageKm == 87_400)
}

@Test func vehicleDraftCollectsAllErrorsAtOnce() {
    let draft = VehicleDraft(kind: .bicycle, make: " ", model: "", yearText: "20x0", mileageText: "-1")

    #expect(
        vehicleFieldErrors(draft) == [
            .make: .required,
            .model: .required,
            .year: .notANumber,
            .mileage: .invalid(.negativeMileage(-1)),
        ])
}

@Test func emptyVehicleDraftReportsEveryField() {
    #expect(
        vehicleFieldErrors(VehicleDraft()) == [
            .make: .required, .model: .required, .year: .required, .mileage: .required,
        ])
}

@Test func makeVehicleKeepsGivenIDAndGeneratesNewOtherwise() throws {
    let draft = validDraft()
    let id = UUID()

    #expect(try draft.makeVehicle(id: id, currentYear: currentYear).id == id)
    #expect(
        try draft.makeVehicle(currentYear: currentYear).id != draft.makeVehicle(currentYear: currentYear).id)
}

@Test func makeVehicleKeepsKind() throws {
    for kind in VehicleKind.allCases {
        var draft = validDraft()
        draft.kind = kind
        #expect(try draft.makeVehicle(currentYear: currentYear).kind == kind)
    }
}
