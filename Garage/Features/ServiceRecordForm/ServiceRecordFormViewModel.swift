import Foundation
import GarageCore
import Observation

/// Состояние формы записи: «Новая запись» или правка существующей. Валидацию и сохранение делают
/// `AddServiceRecord` / `UpdateServiceRecord`, удаление — порт `ServiceRecordEditing` напрямую.
@Observable
final class ServiceRecordFormViewModel {
    typealias Field = ServiceRecordDraft.Field

    enum Mode {
        case add(vehicleID: Vehicle.ID)
        /// `hasStoredReceipt` — у записи есть чек (его байты могут быть ещё не скачаны).
        case edit(original: ServiceRecord, hasStoredReceipt: Bool)
    }

    /// Откуда берётся чек при сохранении. `ReceiptChange` вычисляется из него, отдельных флагов нет.
    enum ReceiptSelection: Equatable {
        /// Чек из базы; `nil` — байты ещё не скачаны.
        case stored(Data?)
        /// Новое фото, выбранное в форме.
        case picked(Data)
        /// Чека нет (не было или удалён в форме).
        case none
    }

    var draft: ServiceRecordDraft
    private(set) var errors: [Field: ServiceRecordDraft.FieldError] = [:]
    private(set) var receiptSelection: ReceiptSelection
    private(set) var isPreparingReceipt = false
    private(set) var isSaving = false
    private(set) var isDeleting = false
    /// Привязаны к алертам вью, поэтому изменяемы снаружи.
    var saveFailed = false
    var deleteFailed = false
    var receiptFailed = false
    /// Запись исчезла (например, удалена на другом устройстве): вью показывает алерт и закрывает форму.
    var recordGone = false
    /// Машину удалили, пока форма была открыта (например, на другом устройстве): вью показывает алерт и
    /// закрывает форму.
    var vehicleGone = false

    let mode: Mode
    let currentMileageKm: Int
    private let addServiceRecord: AddServiceRecord
    private let updateServiceRecord: UpdateServiceRecord
    private let records: any ServiceRecordEditing
    private let receiptPreparer: any ReceiptImagePreparing
    /// Номер последней загрузки чека: результат устаревшей загрузки не должен перетирать новый выбор.
    private var receiptGeneration = 0

    /// - Parameters:
    ///   - storedReceipt: байты чека записи в режиме правки; `nil`, если чека нет или он не скачан.
    ///   - decimalSeparator: разделитель для денег в черновике правки; по умолчанию из текущей локали.
    init(
        mode: Mode, currentMileageKm: Int, storedReceipt: Data? = nil,
        decimalSeparator: Money.DecimalSeparator = ServiceRecordFormViewModel.localeDecimalSeparator,
        addServiceRecord: AddServiceRecord, updateServiceRecord: UpdateServiceRecord,
        records: any ServiceRecordEditing, receiptPreparer: any ReceiptImagePreparing
    ) {
        self.mode = mode
        self.currentMileageKm = currentMileageKm
        self.addServiceRecord = addServiceRecord
        self.updateServiceRecord = updateServiceRecord
        self.records = records
        self.receiptPreparer = receiptPreparer
        switch mode {
        case .add:
            draft = ServiceRecordDraft()
            receiptSelection = .none
        case .edit(let original, let hasStoredReceipt):
            draft = ServiceRecordDraft(record: original, decimalSeparator: decimalSeparator)
            receiptSelection = hasStoredReceipt ? .stored(storedReceipt) : .none
        }
    }

    /// `,` — только если так устроена локаль; `Money(parsing:)` не понимает прочие знаки (например `٫`).
    static var localeDecimalSeparator: Money.DecimalSeparator {
        Locale.current.decimalSeparator == "," ? .comma : .period
    }

    var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    /// Идёт сохранение или удаление: кнопки действий блокируют друг друга.
    var isBusy: Bool { isSaving || isDeleting }

    /// Фото для показа; `nil`, если чека нет или его байты не скачаны.
    var receiptPreview: Data? {
        switch receiptSelection {
        case .stored(let data): data
        case .picked(let data): data
        case .none: nil
        }
    }

    /// У записи есть чек, но его байты ещё не скачаны.
    var isReceiptPending: Bool { receiptSelection == .stored(nil) }

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
    /// за время подготовки не началась другая загрузка и задача не отменена. При неудаче текущий чек
    /// остаётся как был.
    func loadReceipt(_ data: Data?) async {
        receiptGeneration += 1
        let generation = receiptGeneration
        isPreparingReceipt = true
        defer { if generation == receiptGeneration { isPreparingReceipt = false } }
        do {
            guard let data else {
                receiptFailed = true
                return
            }
            let prepared = try await receiptPreparer.prepare(data)
            guard !Task.isCancelled, generation == receiptGeneration else { return }
            receiptSelection = .picked(prepared)
        } catch {
            guard !Task.isCancelled, generation == receiptGeneration else { return }
            receiptFailed = true
        }
    }

    func removeReceipt() {
        receiptGeneration += 1
        receiptSelection = .none
        isPreparingReceipt = false
    }

    /// - Returns: `true`, если запись сохранена и форму можно закрывать.
    func save() async -> Bool {
        guard !isBusy else { return false }
        isSaving = true
        defer { isSaving = false }
        // Ошибки прошлой попытки (в том числе скрытых теперь полей) заменяются результатом этой проверки.
        errors = [:]
        do {
            switch mode {
            case .add(let vehicleID):
                var picked: Data?
                if case .picked(let data) = receiptSelection { picked = data }
                try await addServiceRecord.execute(draft: draft, vehicleID: vehicleID, receipt: picked)
            case .edit(let original, _):
                try await updateServiceRecord.execute(draft: draft, original: original, receipt: receiptChange)
            }
            return true
        } catch let failure as ServiceRecordDraft.Errors {
            errors = failure.fields
        } catch RepositoryError.recordNotFound {
            recordGone = true
        } catch RepositoryError.vehicleNotFound {
            vehicleGone = true
        } catch {
            saveFailed = true
        }
        return false
    }

    /// Удаляет редактируемую запись. Только в режиме правки; повторный вызов во время работы игнорируется.
    /// - Returns: `true`, если запись удалена и форму можно закрывать.
    func delete() async -> Bool {
        guard case .edit(let original, _) = mode, !isBusy else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await records.delete(id: original.id)
            return true
        } catch {
            deleteFailed = true
            return false
        }
    }

    private var receiptChange: ReceiptChange {
        switch receiptSelection {
        case .stored: .keep
        case .picked(let data): .replace(data)
        case .none:
            if case .edit(_, true) = mode { .remove } else { .keep }
        }
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
