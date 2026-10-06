import GarageCore
import SwiftData
import Testing

@testable import GarageStorage

@Test func vehicleSamplesRoundTrip() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    for vehicle in Vehicle.samples {
        let entity = VehicleEntity(vehicle)
        context.insert(entity)
        #expect(try entity.toDomain() == vehicle)
    }
}

@Test func vehicleUpdateChangesFields() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let original = Vehicle.samples[0]
    let entity = VehicleEntity(original)
    context.insert(entity)

    var changed = original
    changed.make = "Lexus"
    changed.model = "LX"
    changed.year = 2023
    changed.kind = .motorcycle
    try changed.updateMileage(100)
    entity.update(from: changed)

    #expect(try entity.toDomain() == changed)
}

@Test func unknownVehicleKindThrows() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let entity = VehicleEntity(Vehicle.samples[0])
    context.insert(entity)
    entity.kindRaw = "boat"

    #expect(throws: StorageMappingError.unknownVehicleKind("boat")) {
        try entity.toDomain()
    }
}

@Test func negativeStoredMileageThrows() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let entity = VehicleEntity(Vehicle.samples[0])
    context.insert(entity)
    entity.mileageKm = -1

    #expect(throws: ValidationError.negativeMileage(-1)) {
        try entity.toDomain()
    }
}
