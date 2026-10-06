import CoreGraphics
import Foundation
import GarageCore
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import GarageStorage

private func makeRecord(
    for vehicle: Vehicle, date: TimeInterval, mileageKm: Int
) throws -> ServiceRecord {
    try ServiceRecord(
        vehicleID: vehicle.id,
        date: Date(timeIntervalSince1970: date),
        mileageKm: mileageKm,
        serviceType: .inspection,
        laborCost: Money(rubles: 100)
    )
}

private func makePNG(width: Int, height: Int) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func properties(of data: Data) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

private func makeStore(vehicles: [Vehicle]) throws -> (ModelContainer, ModelContext, [VehicleEntity]) {
    let container = try GarageStore.makeContainer(inMemory: true)
    let context = ModelContext(container)
    let entities = vehicles.map(VehicleEntity.init)
    entities.forEach(context.insert)
    try context.save()
    return (container, context, entities)
}

@Test func descriptorFiltersByVehicleAndSortsNewestFirst() throws {
    let car = Vehicle.samples[0]
    let bike = Vehicle.samples[2]
    let (container, context, _) = try makeStore(vehicles: [car, bike])
    try ServiceLog.add(makeRecord(for: car, date: 100, mileageKm: 10), toVehicleWithID: car.id, in: container)
    try ServiceLog.add(makeRecord(for: car, date: 300, mileageKm: 20), toVehicleWithID: car.id, in: container)
    try ServiceLog.add(makeRecord(for: car, date: 300, mileageKm: 30), toVehicleWithID: car.id, in: container)
    try ServiceLog.add(makeRecord(for: bike, date: 200, mileageKm: 99), toVehicleWithID: bike.id, in: container)

    let fetched = try context.fetch(ServiceRecordEntity.descriptor(forVehicle: car.id))

    #expect(fetched.map(\.mileageKm) == [30, 20, 10])
}

@Test func addStoresReceiptAndKeepsVehicleMileage() throws {
    let car = Vehicle.samples[0]
    let (container, context, entities) = try makeStore(vehicles: [car])
    let photo = Data([1, 2, 3, 4])

    try ServiceLog.add(
        makeRecord(for: car, date: 100, mileageKm: car.mileageKm + 5_000),
        receiptImage: photo, toVehicleWithID: car.id, in: container)

    let stored = try #require(try context.fetch(ServiceRecordEntity.descriptor(forVehicle: car.id)).first)
    #expect(stored.receiptImage == photo)
    #expect(stored.hasReceipt)
    #expect(entities[0].mileageKm == car.mileageKm)
}

private struct SaveFailure: Error {}

@Test func failedSaveLeavesCallerContextUntouched() throws {
    let car = Vehicle.samples[0]
    let (container, context, entities) = try makeStore(vehicles: [car])
    entities[0].model = "Unsaved edit"
    #expect(context.hasChanges)

    #expect(throws: SaveFailure.self) {
        try ServiceLog.add(
            makeRecord(for: car, date: 1, mileageKm: 1), receiptImage: nil, toVehicleWithID: car.id, in: container
        ) { _ in throw SaveFailure() }
    }

    #expect(entities[0].model == "Unsaved edit")
    #expect(context.hasChanges)
    #expect(entities[0].serviceRecords.isEmpty)
    #expect(try ModelContext(container).fetch(ServiceRecordEntity.descriptor(forVehicle: car.id)).isEmpty)
}

@Test func addWithoutReceiptLeavesImageNil() throws {
    let car = Vehicle.samples[0]
    let (container, context, _) = try makeStore(vehicles: [car])

    try ServiceLog.add(makeRecord(for: car, date: 1, mileageKm: 1), toVehicleWithID: car.id, in: container)

    let stored = try #require(try context.fetch(ServiceRecordEntity.descriptor(forVehicle: car.id)).first)
    #expect(stored.receiptImage == nil)
    #expect(!stored.hasReceipt)
}

@Test func addToUnknownVehicleThrows() throws {
    let car = Vehicle.samples[0]
    let (container, _, _) = try makeStore(vehicles: [])

    #expect(throws: ServiceLogError.vehicleNotFound(car.id)) {
        try ServiceLog.add(makeRecord(for: car, date: 1, mileageKm: 1), toVehicleWithID: car.id, in: container)
    }
}

@Test func prepareDownscalesLargePhotoToJPEG() throws {
    let result = try ReceiptImage.prepare(makePNG(width: 4000, height: 3000))
    let props = try properties(of: result)

    #expect(
        max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 2048)
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 2048)
    #expect(props[kCGImagePropertyPixelHeight] as? Int == 1536)
    #expect(Array(result.prefix(2)) == [0xFF, 0xD8])
    #expect(props[kCGImagePropertyGPSDictionary] == nil)
}

@Test func prepareDoesNotUpscaleSmallPhoto() throws {
    let props = try properties(of: ReceiptImage.prepare(makePNG(width: 400, height: 300)))

    #expect(props[kCGImagePropertyPixelWidth] as? Int == 400)
    #expect(props[kCGImagePropertyPixelHeight] as? Int == 300)
}

@Test func prepareRejectsNonImageData() {
    #expect(throws: ReceiptImageError.unreadableImage) { try ReceiptImage.prepare(Data([1, 2, 3])) }
}
