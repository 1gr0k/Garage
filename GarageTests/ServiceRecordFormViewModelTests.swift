import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct ServiceRecordFormViewModelTests {
    private let vehicleID = Vehicle.samples[0].id

    private func makeModel(
        repository: FakeRecordRepository = FakeRecordRepository(), preparer: FakeReceiptPreparer = .init()
    ) -> ServiceRecordFormViewModel {
        ServiceRecordFormViewModel(
            vehicleID: vehicleID, currentMileageKm: 1_000,
            addServiceRecord: AddServiceRecord(records: repository), receiptPreparer: preparer)
    }

    @Test func invalidDraftFillsErrorsAndSavesNothing() async {
        let repository = FakeRecordRepository()
        let model = makeModel(repository: repository)

        let saved = await model.save()

        #expect(!saved)
        #expect(model.errors[.mileage] != nil)
        #expect(!model.saveFailed)
        #expect(await repository.added.isEmpty)
    }

    @Test func editingFieldClearsItsError() async {
        let model = makeModel()
        _ = await model.save()

        model.clearError(for: .mileage)

        #expect(model.errors[.mileage] == nil)
    }

    @Test func validDraftIsSavedWithReceipt() async {
        let repository = FakeRecordRepository()
        let model = makeModel(repository: repository)
        model.draft.mileageText = "1500"
        await model.loadReceipt(Data([1, 2, 3]))

        let saved = await model.save()

        #expect(saved)
        #expect(model.errors.isEmpty)
        let added = await repository.added
        #expect(added.count == 1)
        #expect(added.first?.record.vehicleID == vehicleID)
        #expect(added.first?.record.mileageKm == 1_500)
        #expect(added.first?.receipt == Data([1, 2, 3]))
    }

    @Test func saveDropsErrorsOfFieldsThatAreNoLongerChecked() async {
        let model = makeModel()
        model.draft.serviceTypeChoice = .other
        _ = await model.save()
        #expect(model.errors[.otherServiceType] != nil)

        model.draft.serviceTypeChoice = .oilChange
        _ = await model.save()

        #expect(model.errors[.otherServiceType] == nil)
        #expect(model.errors[.mileage] != nil)
    }

    @Test func repositoryFailureSetsSaveFailed() async {
        let repository = FakeRecordRepository()
        await repository.failWith(TestFailure())
        let model = makeModel(repository: repository)
        model.draft.mileageText = "1500"

        let saved = await model.save()

        #expect(!saved)
        #expect(model.saveFailed)
        #expect(model.errors.isEmpty)
    }

    @Test func removingPartDropsItsErrors() async {
        let model = makeModel()
        let part = PartDraft()
        model.draft.parts = [part]
        _ = await model.save()
        #expect(model.errors[.partName(part.id)] != nil)

        model.removePart(id: part.id)

        #expect(model.draft.parts.isEmpty)
        #expect(model.errors[.partName(part.id)] == nil)
    }

    @Test func mileageAboveCurrentIsReportedAsNew() {
        let model = makeModel()

        model.draft.mileageText = "900"
        #expect(model.newMileageKm == nil)
        model.draft.mileageText = "1200"
        #expect(model.newMileageKm == 1_200)
    }

    @Test func unreadablePhotoSetsReceiptFailed() async {
        let model = makeModel()

        await model.loadReceipt(nil)

        #expect(model.receiptFailed)
        #expect(model.receipt == nil)
    }

    @Test func preparerFailureSetsReceiptFailed() async {
        let model = makeModel(preparer: FakeReceiptPreparer { _ in throw TestFailure() })

        await model.loadReceipt(Data([1]))

        #expect(model.receiptFailed)
        #expect(model.receipt == nil)
        #expect(!model.isPreparingReceipt)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleReceiptLoadDoesNotOverwriteNewerOne() async {
        let first = Data([1])
        let second = Data([2])
        let gate = Gate()
        let model = makeModel(
            preparer: FakeReceiptPreparer { data in
                if data == first { await gate.arriveAndWait() }
                return data + [0]
            })

        let staleLoad = Task { await model.loadReceipt(first) }
        await gate.waitForArrival()
        await model.loadReceipt(second)
        #expect(model.receipt == second + [0])

        await gate.open()
        await staleLoad.value

        #expect(model.receipt == second + [0])
        #expect(!model.receiptFailed)
        #expect(!model.isPreparingReceipt)
    }

    @Test(.timeLimit(.minutes(1)))
    func removingReceiptDuringPreparationDiscardsIt() async {
        let gate = Gate()
        let model = makeModel(
            preparer: FakeReceiptPreparer { data in
                await gate.arriveAndWait()
                return data
            })

        let load = Task { await model.loadReceipt(Data([1])) }
        await gate.waitForArrival()
        model.removeReceipt()
        await gate.open()
        await load.value

        #expect(model.receipt == nil)
        #expect(!model.isPreparingReceipt)
    }
}
