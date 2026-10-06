import Testing
@testable import GarageCore

@Test func displayNameCombinesMakeAndModel() throws {
    let first = try Vehicle(kind: .car, make: "Toyota", model: "Land Cruiser", year: 2019, mileageKm: 0)
    let second = try Vehicle(kind: .car, make: "Toyota", model: "Land Cruiser", year: 2019, mileageKm: 0)

    #expect(first.displayName == "Toyota Land Cruiser")
    #expect(first.id != second.id)
}

@Test func vehicleStoresKindAndMileage() throws {
    let bike = try Vehicle(kind: .bicycle, make: "Specialized", model: "Rockhopper", year: 2022, mileageKm: 3_120)

    #expect(bike.kind == .bicycle)
    #expect(bike.mileageKm == 3_120)
}

@Test func vehicleRejectsNegativeMileage() {
    #expect(throws: ValidationError.negativeMileage(-1)) {
        try Vehicle(kind: .car, make: "Lada", model: "Niva", year: 2020, mileageKm: -1)
    }
}

@Test func samplesCoverEveryKind() {
    #expect(Set(Vehicle.samples.map(\.kind)) == Set(VehicleKind.allCases))
    #expect(Vehicle.samples.allSatisfy { $0.mileageKm >= 0 })
}

@Test func vehicleRoundTripsThroughJSON() throws {
    let vehicle = Vehicle.samples[2]

    #expect(try roundTrip(vehicle) == vehicle)
}

@Test func decodingVehicleValidatesMileage() {
    let json = """
    {"id":"6F1C1A52-3B7E-4C55-9C2B-1D2E3F405162","kind":"motorcycle","make":"Honda",\
    "model":"CB500X","year":2021,"mileageKm":-5}
    """

    #expect(throws: ValidationError.negativeMileage(-5)) {
        try decode(Vehicle.self, from: json)
    }
}

@Test func updateMileageValidatesAndKeepsOldValueOnFailure() throws {
    var vehicle = try Vehicle(kind: .car, make: "Lada", model: "Niva", year: 2020, mileageKm: 1_000)

    try vehicle.updateMileage(1_500)
    #expect(vehicle.mileageKm == 1_500)

    #expect(throws: ValidationError.negativeMileage(-1)) {
        try vehicle.updateMileage(-1)
    }
    #expect(vehicle.mileageKm == 1_500)
}
