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

@Test func descriptorFiltersByVehicleAndSortsNewestFirst() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let car = Vehicle.samples[0]
    let bike = Vehicle.samples[2]
    let carEntity = VehicleEntity(car)
    let bikeEntity = VehicleEntity(bike)
    context.insert(carEntity)
    context.insert(bikeEntity)
    try ServiceLog.add(makeRecord(for: car, date: 100, mileageKm: 10), to: carEntity, in: context)
    try ServiceLog.add(makeRecord(for: car, date: 300, mileageKm: 20), to: carEntity, in: context)
    try ServiceLog.add(makeRecord(for: car, date: 300, mileageKm: 30), to: carEntity, in: context)
    try ServiceLog.add(makeRecord(for: bike, date: 200, mileageKm: 99), to: bikeEntity, in: context)

    let fetched = try context.fetch(ServiceRecordEntity.descriptor(forVehicle: car.id))

    #expect(fetched.map(\.mileageKm) == [30, 20, 10])
}

@Test func addStoresReceiptAndKeepsVehicleMileage() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let car = Vehicle.samples[0]
    let entity = VehicleEntity(car)
    context.insert(entity)
    let photo = Data([1, 2, 3, 4])

    try ServiceLog.add(
        makeRecord(for: car, date: 100, mileageKm: car.mileageKm + 5_000),
        receiptImage: photo, to: entity, in: context)

    let stored = try #require(try context.fetch(ServiceRecordEntity.descriptor(forVehicle: car.id)).first)
    #expect(stored.receiptImage == photo)
    #expect(stored.hasReceipt)
    #expect(entity.mileageKm == car.mileageKm)
}

private struct SaveFailure: Error {}

@Test func failedSaveRollsBackTheInsertedRecord() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let car = Vehicle.samples[0]
    let entity = VehicleEntity(car)
    context.insert(entity)
    try context.save()

    #expect(throws: SaveFailure.self) {
        try ServiceLog.add(
            makeRecord(for: car, date: 1, mileageKm: 1), receiptImage: nil, to: entity, in: context
        ) { _ in throw SaveFailure() }
    }

    #expect(entity.serviceRecords.isEmpty)
    #expect(try context.fetch(ServiceRecordEntity.descriptor(forVehicle: car.id)).isEmpty)
    #expect(!context.hasChanges)
}

@Test func addWithoutReceiptLeavesImageNil() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let car = Vehicle.samples[0]
    let entity = VehicleEntity(car)
    context.insert(entity)

    let stored = try ServiceLog.add(makeRecord(for: car, date: 1, mileageKm: 1), to: entity, in: context)

    #expect(stored.receiptImage == nil)
    #expect(!stored.hasReceipt)
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
