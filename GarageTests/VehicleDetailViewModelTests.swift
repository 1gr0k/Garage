import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct VehicleDetailViewModelTests {
    private let recordID = UUID()
    private let vehicleID = UUID()

    private func makeModel(
        records: FakeRecordRepository = FakeRecordRepository(),
        vehicles: FakeVehicleRepository = FakeVehicleRepository()
    ) -> VehicleDetailViewModel {
        VehicleDetailViewModel(records: records, vehicles: vehicles)
    }

    @Test func confirmedDeletionDeletesRecord() async {
        let repository = FakeRecordRepository()
        let model = makeModel(records: repository)
        model.pendingDeletion = recordID

        await model.delete(id: recordID)

        #expect(await repository.deleted == [recordID])
        #expect(model.pendingDeletion == nil)
        #expect(!model.deleteFailed)
    }

    @Test func cancelledConfirmationCallsNothing() async {
        let repository = FakeRecordRepository()
        let model = makeModel(records: repository)

        model.pendingDeletion = recordID
        model.pendingDeletion = nil

        #expect(await repository.deleted.isEmpty)
    }

    @Test func failureSetsDeleteFailed() async {
        let repository = FakeRecordRepository()
        await repository.failDelete(with: TestFailure())
        let model = makeModel(records: repository)

        await model.delete(id: recordID)

        #expect(model.deleteFailed)
        #expect(!model.isDeleting)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedDeleteWhileRunningCallsOnce() async {
        let repository = FakeRecordRepository()
        let gate = Gate()
        await repository.holdDelete(at: gate)
        let model = makeModel(records: repository)

        let first = Task { await model.delete(id: recordID) }
        await gate.waitForArrival()
        await model.delete(id: recordID)
        await gate.open()
        await first.value

        #expect(await repository.deleted.count == 1)
    }

    // MARK: Удаление машины

    @Test func deleteVehicleSucceeds() async {
        let vehicles = FakeVehicleRepository()
        let model = makeModel(vehicles: vehicles)
        model.isConfirmingVehicleDeletion = true

        let deleted = await model.deleteVehicle(id: vehicleID)

        #expect(deleted)
        #expect(await vehicles.deleted == [vehicleID])
        #expect(!model.isConfirmingVehicleDeletion)
        #expect(!model.vehicleDeleteFailed)
    }

    @Test func deleteVehicleFailureSetsFlag() async {
        let vehicles = FakeVehicleRepository()
        await vehicles.failDelete(with: TestFailure())
        let model = makeModel(vehicles: vehicles)

        let deleted = await model.deleteVehicle(id: vehicleID)

        #expect(!deleted)
        #expect(model.vehicleDeleteFailed)
        #expect(!model.deleteFailed)
        #expect(!model.isDeleting)
    }

    @Test(.timeLimit(.minutes(1)))
    func recordDeletionDuringVehicleDeletionIsIgnored() async {
        let records = FakeRecordRepository()
        let vehicles = FakeVehicleRepository()
        let gate = Gate()
        await vehicles.holdDelete(at: gate)
        let model = makeModel(records: records, vehicles: vehicles)

        let vehicleDeletion = Task { await model.deleteVehicle(id: vehicleID) }
        await gate.waitForArrival()
        await model.delete(id: recordID)
        await gate.open()
        let deleted = await vehicleDeletion.value

        #expect(deleted)
        #expect(await records.deleted.isEmpty)
        #expect(await vehicles.deleted == [vehicleID])
    }

    @Test(.timeLimit(.minutes(1)))
    func vehicleDeletionDuringRecordDeletionIsIgnored() async {
        let records = FakeRecordRepository()
        let vehicles = FakeVehicleRepository()
        let gate = Gate()
        await records.holdDelete(at: gate)
        let model = makeModel(records: records, vehicles: vehicles)

        let recordDeletion = Task { await model.delete(id: recordID) }
        await gate.waitForArrival()
        let deleted = await model.deleteVehicle(id: vehicleID)
        await gate.open()
        await recordDeletion.value

        #expect(!deleted)
        #expect(await vehicles.deleted.isEmpty)
    }
}
