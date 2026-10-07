import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct VehicleListViewModelTests {
    private let vehicleID = UUID()

    @Test func confirmedDeletionDeletesVehicle() async {
        let repository = FakeVehicleRepository()
        let model = VehicleListViewModel(vehicles: repository)
        model.pendingDeletion = vehicleID

        await model.delete(id: vehicleID)

        #expect(await repository.deleted == [vehicleID])
        #expect(model.pendingDeletion == nil)
        #expect(!model.deleteFailed)
    }

    @Test func cancelledConfirmationCallsNothing() async {
        let repository = FakeVehicleRepository()
        let model = VehicleListViewModel(vehicles: repository)

        model.pendingDeletion = vehicleID
        model.pendingDeletion = nil

        #expect(await repository.deleted.isEmpty)
    }

    @Test func failureSetsDeleteFailed() async {
        let repository = FakeVehicleRepository()
        await repository.failDelete(with: TestFailure())
        let model = VehicleListViewModel(vehicles: repository)

        await model.delete(id: vehicleID)

        #expect(model.deleteFailed)
        #expect(!model.isDeleting)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedDeleteWhileRunningCallsOnce() async {
        let repository = FakeVehicleRepository()
        let gate = Gate()
        await repository.holdDelete(at: gate)
        let model = VehicleListViewModel(vehicles: repository)

        let first = Task { await model.delete(id: vehicleID) }
        await gate.waitForArrival()
        await model.delete(id: vehicleID)
        await gate.open()
        await first.value

        #expect(await repository.deleted.count == 1)
    }
}
