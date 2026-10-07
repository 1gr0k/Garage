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
            mode: .add(vehicleID: vehicleID), currentMileageKm: 1_000,
            addServiceRecord: AddServiceRecord(records: repository),
            updateServiceRecord: UpdateServiceRecord(records: repository), records: repository,
            receiptPreparer: preparer)
    }

    private func makeEditModel(
        _ original: ServiceRecord, hasStoredReceipt: Bool = false, storedReceipt: Data? = nil,
        decimalSeparator: Money.DecimalSeparator = .period,
        repository: FakeRecordRepository = FakeRecordRepository(), preparer: FakeReceiptPreparer = .init()
    ) -> ServiceRecordFormViewModel {
        ServiceRecordFormViewModel(
            mode: .edit(original: original, hasStoredReceipt: hasStoredReceipt), currentMileageKm: 1_000,
            storedReceipt: storedReceipt, decimalSeparator: decimalSeparator,
            addServiceRecord: AddServiceRecord(records: repository),
            updateServiceRecord: UpdateServiceRecord(records: repository), records: repository,
            receiptPreparer: preparer)
    }

    private func makeOriginal() throws -> ServiceRecord {
        try ServiceRecord(
            vehicleID: vehicleID, date: Date(timeIntervalSince1970: 1_700_000_000), mileageKm: 900,
            serviceType: .brakes, laborCost: Money(kopecks: 125_050), notes: "заметка",
            parts: [Part(name: "Колодки", unitPrice: Money(rubles: 1_000), quantity: 2)])
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
        #expect(model.receiptPreview == nil)
    }

    @Test func preparerFailureSetsReceiptFailed() async {
        let model = makeModel(preparer: FakeReceiptPreparer { _ in throw TestFailure() })

        await model.loadReceipt(Data([1]))

        #expect(model.receiptFailed)
        #expect(model.receiptPreview == nil)
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
        #expect(model.receiptPreview == second + [0])

        await gate.open()
        await staleLoad.value

        #expect(model.receiptPreview == second + [0])
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

        #expect(model.receiptPreview == nil)
        #expect(!model.isPreparingReceipt)
    }

    // MARK: Режим правки

    @Test func editDraftIsFilledFromRecord() throws {
        let original = try makeOriginal()

        let model = makeEditModel(original, decimalSeparator: .comma)

        #expect(model.isEditing)
        #expect(model.draft.mileageText == "900")
        #expect(model.draft.serviceTypeChoice == .brakes)
        #expect(model.draft.laborCostText == "1250,50")
        #expect(model.draft.notes == "заметка")
        #expect(model.draft.parts.map(\.id) == original.parts.map(\.id))
        #expect(model.receiptPreview == nil)
    }

    @Test func localeSeparatorIsPeriodUnlessLocaleUsesComma() {
        let expected: Money.DecimalSeparator = Locale.current.decimalSeparator == "," ? .comma : .period
        #expect(ServiceRecordFormViewModel.localeDecimalSeparator == expected)
    }

    @Test func unchangedEditWithoutReceiptCallsNothing() async throws {
        let repository = FakeRecordRepository()
        let model = makeEditModel(try makeOriginal(), repository: repository)

        #expect(await model.save())

        #expect(await repository.updated.isEmpty)
    }

    @Test func editKeepsStoredReceipt() async throws {
        let repository = FakeRecordRepository()
        let original = try makeOriginal()
        let model = makeEditModel(
            original, hasStoredReceipt: true, storedReceipt: Data([1]), repository: repository)
        model.draft.mileageText = "950"

        #expect(await model.save())

        let updated = await repository.updated
        #expect(updated.count == 1)
        #expect(updated.first?.record.id == original.id)
        #expect(updated.first?.record.mileageKm == 950)
        #expect(updated.first?.receipt == .keep)
    }

    @Test func notYetDownloadedReceiptIsKeptOnSave() async throws {
        let repository = FakeRecordRepository()
        let model = makeEditModel(
            try makeOriginal(), hasStoredReceipt: true, storedReceipt: nil, repository: repository)
        model.draft.notes = "другое"

        #expect(model.isReceiptPending)
        #expect(await model.save())

        #expect(await repository.updated.first?.receipt == .keep)
    }

    @Test func pickedReceiptIsReplaced() async throws {
        let repository = FakeRecordRepository()
        let model = makeEditModel(
            try makeOriginal(), hasStoredReceipt: true, storedReceipt: Data([1]), repository: repository)
        await model.loadReceipt(Data([2]))

        #expect(model.receiptPreview == Data([2]))
        #expect(await model.save())

        #expect(await repository.updated.first?.receipt == .replace(Data([2])))
    }

    @Test func failedPickKeepsStoredReceipt() async throws {
        let model = makeEditModel(
            try makeOriginal(), hasStoredReceipt: true, storedReceipt: Data([1]),
            preparer: FakeReceiptPreparer { _ in throw TestFailure() })

        await model.loadReceipt(Data([2]))

        #expect(model.receiptFailed)
        #expect(model.receiptPreview == Data([1]))
    }

    @Test func removedStoredReceiptIsRemoved() async throws {
        let repository = FakeRecordRepository()
        let model = makeEditModel(
            try makeOriginal(), hasStoredReceipt: true, storedReceipt: Data([1]), repository: repository)
        model.removeReceipt()

        #expect(await model.save())

        // Даже без других правок: удаление чека — изменение.
        #expect(await repository.updated.first?.receipt == .remove)
    }

    @Test func removedNotYetDownloadedReceiptIsRemoved() async throws {
        let repository = FakeRecordRepository()
        let model = makeEditModel(
            try makeOriginal(), hasStoredReceipt: true, storedReceipt: nil, repository: repository)
        model.removeReceipt()

        #expect(await model.save())

        #expect(await repository.updated.first?.receipt == .remove)
    }

    @Test func recordWithoutReceiptKeepsItWhenNothingPicked() async throws {
        let repository = FakeRecordRepository()
        let model = makeEditModel(try makeOriginal(), repository: repository)
        model.removeReceipt()
        model.draft.notes = "x"

        #expect(await model.save())

        #expect(await repository.updated.first?.receipt == .keep)
    }

    @Test func invalidEditDraftFillsErrorsAndCallsNothing() async throws {
        let repository = FakeRecordRepository()
        let model = makeEditModel(try makeOriginal(), repository: repository)
        model.draft.mileageText = ""

        #expect(!(await model.save()))

        #expect(model.errors[.mileage] != nil)
        #expect(await repository.updated.isEmpty)
    }

    @Test func missingRecordOnSaveSetsRecordGone() async throws {
        let repository = FakeRecordRepository()
        let original = try makeOriginal()
        await repository.failUpdate(with: RepositoryError.recordNotFound(original.id))
        let model = makeEditModel(original, repository: repository)
        model.draft.notes = "x"

        #expect(!(await model.save()))

        #expect(model.recordGone)
        #expect(!model.saveFailed)
    }

    @Test func otherUpdateFailureSetsSaveFailed() async throws {
        let repository = FakeRecordRepository()
        await repository.failUpdate(with: TestFailure())
        let model = makeEditModel(try makeOriginal(), repository: repository)
        model.draft.notes = "x"

        #expect(!(await model.save()))

        #expect(model.saveFailed)
        #expect(!model.recordGone)
    }

    @Test func deleteRemovesRecord() async throws {
        let repository = FakeRecordRepository()
        let original = try makeOriginal()
        let model = makeEditModel(original, repository: repository)

        #expect(await model.delete())

        #expect(await repository.deleted == [original.id])
        #expect(!model.deleteFailed)
    }

    @Test func deleteFailureSetsDeleteFailed() async throws {
        let repository = FakeRecordRepository()
        await repository.failDelete(with: TestFailure())
        let model = makeEditModel(try makeOriginal(), repository: repository)

        #expect(!(await model.delete()))

        #expect(model.deleteFailed)
        #expect(!model.isDeleting)
    }

    @Test func deleteInAddModeDoesNothing() async {
        let repository = FakeRecordRepository()
        let model = makeModel(repository: repository)

        #expect(!(await model.delete()))

        #expect(await repository.deleted.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedDeleteWhileRunningCallsOnce() async throws {
        let repository = FakeRecordRepository()
        let gate = Gate()
        await repository.holdDelete(at: gate)
        let model = makeEditModel(try makeOriginal(), repository: repository)

        let first = Task { await model.delete() }
        await gate.waitForArrival()
        #expect(model.isDeleting)
        let second = await model.delete()
        await gate.open()
        let firstResult = await first.value

        #expect(!second)
        #expect(firstResult)
        #expect(await repository.deleted.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func saveDuringDeleteIsIgnored() async throws {
        let repository = FakeRecordRepository()
        let gate = Gate()
        await repository.holdDelete(at: gate)
        let model = makeEditModel(try makeOriginal(), repository: repository)
        model.draft.notes = "x"

        let deletion = Task { await model.delete() }
        await gate.waitForArrival()
        let saved = await model.save()
        await gate.open()
        _ = await deletion.value

        #expect(!saved)
        #expect(await repository.updated.isEmpty)
    }
}
