import Foundation
import GarageAPI
import GarageCore
import Testing

@testable import GarageSync

@Suite struct MappingTests {
    @Test func vehicleGoldenRoundTrips() throws {
        let data = try GoldenExamples.data("vehicle")
        let dto = try APICoding.makeDecoder().decode(VehicleDTO.self, from: data)
        let vehicle = try Vehicle(dto: dto)
        #expect(vehicle.kind == .motorcycle)
        #expect(VehicleDTO(vehicle) == dto)
        #expect(try JSONValue(data: APICoding.makeEncoder().encode(VehicleDTO(vehicle))) == JSONValue(data: data))
    }

    @Test func serviceRecordGoldenRoundTrips() throws {
        let data = try GoldenExamples.data("service-record")
        let dto = try APICoding.makeDecoder().decode(ServiceRecordDTO.self, from: data)
        let (record, extras) = try ServiceRecord.decoded(from: dto)
        #expect(record.serviceType == .brakes)
        #expect(record.parts.count == 2)
        #expect(record.parts[0].partNumber == "04465-60320")
        #expect(record.parts[0].unitPrice == Money(kopecks: 520_000))
        #expect(record.parts[1].partNumber == nil)
        #expect(extras.receipt == dto.receipt)
        #expect(extras.rawServiceType == nil)
        #expect(ServiceRecordDTO(record, extras: extras) == dto)
        let encoded = try APICoding.makeEncoder().encode(ServiceRecordDTO(record, extras: extras))
        #expect(try JSONValue(data: encoded) == JSONValue(data: data))
    }

    @Test func unknownServiceTypeIsKeptAndSentBack() throws {
        var dto = ServiceRecordDTO(makeRecord(), extras: RecordSyncExtras())
        dto.serviceType = "battery"
        let (record, extras) = try ServiceRecord.decoded(from: dto)
        #expect(record.serviceType == .other("battery"))
        #expect(extras.rawServiceType == "battery")
        #expect(ServiceRecordDTO(record, extras: extras).serviceType == "battery")
    }

    @Test func userChosenTypesAreEncodedFromTheDomain() throws {
        let extras = RecordSyncExtras(rawServiceType: "battery")
        #expect(ServiceRecordDTO(makeRecord(serviceType: .brakes), extras: extras).serviceType == "brakes")
        // Chosen by the user, no raw value: the regular storage form.
        #expect(
            ServiceRecordDTO(makeRecord(serviceType: .other("battery")), extras: RecordSyncExtras()).serviceType
                == "other:battery")
    }

    @Test func unknownVehicleKindThrows() {
        let dto = VehicleDTO(id: IDs.vehicle, kind: "spaceship", make: "A", model: "B", year: 2000, mileageKm: 1)
        #expect(throws: SyncMappingError.unknownVehicleKind("spaceship")) { try Vehicle(dto: dto) }
    }

    @Test func negativeMileageThrowsValidationError() {
        let dto = VehicleDTO(id: IDs.vehicle, kind: "car", make: "A", model: "B", year: 2000, mileageKm: -5)
        #expect(throws: ValidationError.negativeMileage(-5)) { try Vehicle(dto: dto) }
    }
}
