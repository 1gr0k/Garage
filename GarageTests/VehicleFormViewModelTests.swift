import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct VehicleFormViewModelTests {
    private let year = 2026

    private func makeModel(
        mode: VehicleFormViewModel.Mode = .add, recordsMileageKm: Int? = nil,
        repository: FakeVehicleRepository = FakeVehicleRepository()
    ) -> VehicleFormViewModel {
        VehicleFormViewModel(
            mode: mode, recordsMileageKm: recordsMileageKm,
            addVehicle: AddVehicle(vehicles: repository), updateVehicle: UpdateVehicle(vehicles: repository),
            currentYear: { year })
    }

    private func fill(_ model: VehicleFormViewModel) {
        model.draft = VehicleDraft(kind: .car, make: "Mazda", model: "3", yearText: "2020", mileageText: "1500")
    }

    private func makeOriginal() throws -> Vehicle {
        try Vehicle(kind: .motorcycle, make: "Honda", model: "CB500X", year: 2021, mileageKm: 18_250)
    }

    @Test func editDraftIsFilledFromVehicle() throws {
        let original = try makeOriginal()

        let model = makeModel(mode: .edit(original: original))

        #expect(model.draft == VehicleDraft(vehicle: original))
        #expect(model.isEditing)
        #expect(model.errors.isEmpty)
    }

    @Test func invalidOriginalShowsErrorsOnOpen() throws {
        let original = try Vehicle(kind: .car, make: "  ", model: "X", year: 1800, mileageKm: 0)

        let model = makeModel(mode: .edit(original: original))

        #expect(model.errors[.make] == .required)
        #expect(model.errors[.year] != nil)
        #expect(model.errors[.model] == nil)
    }

    @Test func invalidDraftFillsErrorsAndSavesNothing() async {
        let repository = FakeVehicleRepository()
        let model = makeModel(repository: repository)

        let saved = await model.save()

        #expect(!saved)
        #expect(model.errors[.make] == .required)
        #expect(model.errors[.model] == .required)
        #expect(model.errors[.year] != nil)
        #expect(model.errors[.mileage] != nil)
        #expect(!model.saveFailed)
        #expect(await repository.added.isEmpty)
    }

    @Test func editingFieldClearsItsError() async {
        let model = makeModel()
        _ = await model.save()

        model.clearError(for: .make)

        #expect(model.errors[.make] == nil)
        #expect(model.errors[.model] == .required)
    }

    @Test func addCallsAddVehicle() async {
        let repository = FakeVehicleRepository()
        let model = makeModel(repository: repository)
        fill(model)

        let saved = await model.save()

        #expect(saved)
        let added = await repository.added
        #expect(added.count == 1)
        #expect(added.first?.make == "Mazda")
        #expect(await repository.updated.isEmpty)
    }

    @Test func editCallsUpdateVehicleKeepingID() async throws {
        let repository = FakeVehicleRepository()
        let original = try makeOriginal()
        let model = makeModel(mode: .edit(original: original), repository: repository)
        model.draft.yearText = "2022"

        let saved = await model.save()

        #expect(saved)
        let updated = await repository.updated
        #expect(updated.count == 1)
        #expect(updated.first?.id == original.id)
        #expect(updated.first?.year == 2022)
        #expect(await repository.added.isEmpty)
    }

    @Test func unchangedEditDoesNotCallRepository() async throws {
        let repository = FakeVehicleRepository()
        let model = makeModel(mode: .edit(original: try makeOriginal()), repository: repository)

        let saved = await model.save()

        #expect(saved)
        #expect(await repository.updated.isEmpty)
    }

    @Test func missingVehicleOnEditSetsVehicleGone() async throws {
        let repository = FakeVehicleRepository()
        let original = try makeOriginal()
        await repository.failUpdate(with: RepositoryError.vehicleNotFound(original.id))
        let model = makeModel(mode: .edit(original: original), repository: repository)
        model.draft.yearText = "2022"

        #expect(!(await model.save()))

        #expect(model.vehicleGone)
        #expect(!model.saveFailed)
    }

    @Test func otherFailureSetsSaveFailed() async {
        let repository = FakeVehicleRepository()
        await repository.failAdd(with: TestFailure())
        let model = makeModel(repository: repository)
        fill(model)

        #expect(!(await model.save()))

        #expect(model.saveFailed)
        #expect(!model.vehicleGone)
        #expect(!model.isSaving)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedSaveWhileRunningCallsOnce() async throws {
        let repository = FakeVehicleRepository()
        let gate = Gate()
        await repository.holdAdd(at: gate)
        let model = makeModel(repository: repository)
        fill(model)

        let first = Task { await model.save() }
        await gate.waitForArrival()
        let second = await model.save()
        await gate.open()
        let firstSaved = await first.value

        #expect(!second)
        #expect(firstSaved)
        #expect(await repository.added.count == 1)
    }

    @Test func recordsMileageHintAppearsOnlyWhenRecordsAreHigher() throws {
        let original = try makeOriginal()
        let model = makeModel(mode: .edit(original: original), recordsMileageKm: 20_000)

        #expect(model.recordsMileageHintKm == 20_000)

        model.draft.mileageText = "25000"
        #expect(model.recordsMileageHintKm == nil)

        model.draft.mileageText = "abc"
        #expect(model.recordsMileageHintKm == nil)
    }

    // T7: форма правки машины с незнакомым видом, решение 9e плана этапа 12.

    @Test func editFormOfUnrecognizedKindShowsNoChosenKind() throws {
        let model = makeModel(mode: .edit(original: try makeOriginal(), unrecognizedKind: "tractor"))

        #expect(model.draft.kind == nil)
        #expect(model.draft.unrecognizedKind == "tractor")
        #expect(model.errors.isEmpty)
    }

    @Test func savingWithoutChoosingAKeepsTheUnrecognizedKind() async throws {
        let repository = FakeVehicleRepository()
        let model = makeModel(
            mode: .edit(original: try makeOriginal(), unrecognizedKind: "tractor"), repository: repository)
        model.draft.make = "Yamaha"

        #expect(await model.save())

        #expect(await repository.updated.map(\.make) == ["Yamaha"])
        #expect(await repository.kindChanges == [.keepUnrecognized])
    }

    /// Положительный контроль: явный выбор вида в форме сбрасывает сырое значение.
    @Test func savingAfterChoosingAKindSetsIt() async throws {
        let repository = FakeVehicleRepository()
        let original = try makeOriginal()
        let model = makeModel(mode: .edit(original: original, unrecognizedKind: "tractor"), repository: repository)
        model.draft.kind = original.kind

        #expect(await model.save())

        #expect(await repository.kindChanges == [.set])
    }

    @Test func noHintWithoutRecordsMileage() throws {
        let model = makeModel(mode: .edit(original: try makeOriginal()))

        #expect(model.recordsMileageHintKm == nil)
    }
}
