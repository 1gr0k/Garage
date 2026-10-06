import Foundation
import GarageCore
import SwiftData
import Testing

@testable import GarageStorage

private func makeRecord(for vehicle: Vehicle) throws -> ServiceRecord {
    try ServiceRecord(
        vehicleID: vehicle.id,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        mileageKm: 87_000,
        serviceType: .other("Замена свечей"),
        laborCost: Money(rubles: 1_500, kopecks: 50),
        notes: "Заметка",
        parts: [
            Part(name: "Свеча", partNumber: "NGK-1", unitPrice: Money(rubles: 450), quantity: 4),
            Part(name: "Прокладка", unitPrice: Money(kopecks: 9_990)),
            Part(name: "Герметик", partNumber: "X", unitPrice: Money(rubles: 300), quantity: 2),
        ]
    )
}

private struct Fixture {
    let context: ModelContext
    let vehicle: Vehicle
    let vehicleEntity: VehicleEntity

    init() throws {
        context = ModelContext(try GarageStore.makeContainer(inMemory: true))
        vehicle = Vehicle.samples[0]
        vehicleEntity = VehicleEntity(vehicle)
        context.insert(vehicleEntity)
    }
}

@Test func serviceRecordRoundTripKeepsPartsOrder() throws {
    let f = try Fixture()
    let record = try makeRecord(for: f.vehicle)
    let entity = try ServiceRecordEntity(record, vehicle: f.vehicleEntity)
    f.context.insert(entity)

    let restored = try entity.toDomain()
    #expect(restored == record)
    #expect(restored.parts.map(\.name) == ["Свеча", "Прокладка", "Герметик"])
    #expect(restored.parts[1].partNumber == nil)
    #expect(restored.totalCost == record.totalCost)
}

@Test func vehicleMismatchThrows() throws {
    let f = try Fixture()
    let other = Vehicle.samples[1]
    let record = try makeRecord(for: other)

    #expect(throws: StorageMappingError.vehicleMismatch(expected: other.id, actual: f.vehicle.id)) {
        try ServiceRecordEntity(record, vehicle: f.vehicleEntity)
    }
}

@Test func missingVehicleThrows() throws {
    let f = try Fixture()
    let record = try makeRecord(for: f.vehicle)
    let entity = try ServiceRecordEntity(record, vehicle: f.vehicleEntity)
    f.context.insert(entity)
    entity.vehicle = nil

    #expect(throws: StorageMappingError.missingVehicle(record.id)) {
        try entity.toDomain()
    }
}

@Test func invalidServiceTypeThrows() throws {
    let f = try Fixture()
    let entity = try ServiceRecordEntity(try makeRecord(for: f.vehicle), vehicle: f.vehicleEntity)
    f.context.insert(entity)
    entity.serviceTypeRaw = "tuning"

    #expect(throws: ValidationError.unknownServiceType("tuning")) {
        try entity.toDomain()
    }
}

@Test func zeroStoredQuantityThrows() throws {
    let f = try Fixture()
    let entity = try ServiceRecordEntity(try makeRecord(for: f.vehicle), vehicle: f.vehicleEntity)
    f.context.insert(entity)
    entity.parts[0].quantity = 0

    #expect(throws: ValidationError.nonPositiveQuantity(0)) {
        try entity.toDomain()
    }
}

@Test func storedServiceTypeStringIsStable() throws {
    let f = try Fixture()
    var record = try makeRecord(for: f.vehicle)
    let custom = try ServiceRecordEntity(record, vehicle: f.vehicleEntity)
    record.serviceType = .oilChange
    let oil = try ServiceRecordEntity(record, vehicle: f.vehicleEntity)

    #expect(custom.serviceTypeRaw == "other:Замена свечей")
    #expect(oil.serviceTypeRaw == "oilChange")
}

@Test func updateRebuildsParts() throws {
    let f = try Fixture()
    var record = try makeRecord(for: f.vehicle)
    let entity = try ServiceRecordEntity(record, vehicle: f.vehicleEntity)
    f.context.insert(entity)
    try f.context.save()

    record.parts = [try Part(name: "Масло", unitPrice: Money(rubles: 900))]
    record.notes = "Новая"
    entity.update(from: record)
    try f.context.save()

    #expect(try entity.toDomain() == record)
    #expect(try f.context.fetchCount(FetchDescriptor<PartEntity>()) == 1)
}

@Test func deletingVehicleCascades() throws {
    let f = try Fixture()
    let entity = try ServiceRecordEntity(try makeRecord(for: f.vehicle), vehicle: f.vehicleEntity)
    f.context.insert(entity)
    try f.context.save()
    #expect(try f.context.fetchCount(FetchDescriptor<ServiceRecordEntity>()) == 1)
    #expect(try f.context.fetchCount(FetchDescriptor<PartEntity>()) == 3)

    f.context.delete(f.vehicleEntity)
    try f.context.save()

    #expect(try f.context.fetchCount(FetchDescriptor<ServiceRecordEntity>()) == 0)
    #expect(try f.context.fetchCount(FetchDescriptor<PartEntity>()) == 0)
}
