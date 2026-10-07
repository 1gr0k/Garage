import Foundation
import GarageCore
import Observation

/// Состояние формы «Новая запись». Валидацию и сохранение делает `AddServiceRecord`.
@Observable
final class ServiceRecordFormViewModel {
    typealias Field = ServiceRecordDraft.Field

    var draft = ServiceRecordDraft()
    private(set) var errors: [Field: ServiceRecordDraft.FieldError] = [:]
    private(set) var receipt: Data?
    private(set) var isPreparingReceipt = false
    private(set) var isSaving = false
    /// Привязаны к алертам вью, поэтому изменяемы снаружи.
    var saveFailed = false
    var receiptFailed = false

    let currentMileageKm: Int
    private let vehicleID: Vehicle.ID
    private let addServiceRecord: AddServiceRecord
    private let receiptPreparer: any ReceiptImagePreparing
    /// Номер последней загрузки чека: результат устаревшей загрузки не должен перетирать новый выбор.
    private var receiptGeneration = 0

    init(
        vehicleID: Vehicle.ID, currentMileageKm: Int, addServiceRecord: AddServiceRecord,
        receiptPreparer: any ReceiptImagePreparing
    ) {
        self.vehicleID = vehicleID
        self.currentMileageKm = currentMileageKm
        self.addServiceRecord = addServiceRecord
        self.receiptPreparer = receiptPreparer
    }

    /// Пробег, который получит машина, если он больше текущего (для подсказки под полем).
    var newMileageKm: Int? {
        guard case .success(let value) = ServiceRecordDraft.parseMileage(draft.mileageText), value > currentMileageKm
        else { return nil }
        return value
    }

    func clearError(for field: Field) {
        errors[field] = nil
    }

    func removePart(id: UUID) {
        draft.parts.removeAll { $0.id == id }
        errors = errors.filter { key, _ in key.partID != id }
    }

    /// Готовит выбранное фото. `nil` — фото не удалось прочитать. Результат применяется, только если
    /// за время подготовки не началась другая загрузка и задача не отменена.
    func loadReceipt(_ data: Data?) async {
        receiptGeneration += 1
        let generation = receiptGeneration
        receipt = nil
        isPreparingReceipt = true
        defer { if generation == receiptGeneration { isPreparingReceipt = false } }
        do {
            guard let data else {
                receiptFailed = true
                return
            }
            let prepared = try await receiptPreparer.prepare(data)
            guard !Task.isCancelled, generation == receiptGeneration else { return }
            receipt = prepared
        } catch {
            guard !Task.isCancelled, generation == receiptGeneration else { return }
            receiptFailed = true
        }
    }

    func removeReceipt() {
        receiptGeneration += 1
        receipt = nil
        isPreparingReceipt = false
    }

    /// - Returns: `true`, если запись сохранена и форму можно закрывать.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        // Ошибки прошлой попытки (в том числе скрытых теперь полей) заменяются результатом этой проверки.
        errors = [:]
        do {
            try await addServiceRecord.execute(draft: draft, vehicleID: vehicleID, receipt: receipt)
            return true
        } catch let failure as ServiceRecordDraft.Errors {
            errors = failure.fields
        } catch {
            saveFailed = true
        }
        return false
    }
}

extension ServiceRecordDraft.Field {
    fileprivate var partID: UUID? {
        switch self {
        case .partName(let id), .partUnitPrice(let id), .partQuantity(let id): id
        default: nil
        }
    }
}
