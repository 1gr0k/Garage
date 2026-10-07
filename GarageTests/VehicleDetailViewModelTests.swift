import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct VehicleDetailViewModelTests {
    private let recordID = UUID()

    @Test func confirmedDeletionDeletesRecord() async {
        let repository = FakeRecordRepository()
        let model = VehicleDetailViewModel(records: repository)
        model.pendingDeletion = recordID

        await model.delete(id: recordID)

        #expect(await repository.deleted == [recordID])
        #expect(model.pendingDeletion == nil)
        #expect(!model.deleteFailed)
    }

    @Test func cancelledConfirmationCallsNothing() async {
        let repository = FakeRecordRepository()
        let model = VehicleDetailViewModel(records: repository)

        model.pendingDeletion = recordID
        model.pendingDeletion = nil

        #expect(await repository.deleted.isEmpty)
    }

    @Test func failureSetsDeleteFailed() async {
        let repository = FakeRecordRepository()
        await repository.failDelete(with: TestFailure())
        let model = VehicleDetailViewModel(records: repository)

        await model.delete(id: recordID)

        #expect(model.deleteFailed)
        #expect(!model.isDeleting)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedDeleteWhileRunningCallsOnce() async {
        let repository = FakeRecordRepository()
        let gate = Gate()
        await repository.holdDelete(at: gate)
        let model = VehicleDetailViewModel(records: repository)

        let first = Task { await model.delete(id: recordID) }
        await gate.waitForArrival()
        await model.delete(id: recordID)
        await gate.open()
        await first.value

        #expect(await repository.deleted.count == 1)
    }
}
