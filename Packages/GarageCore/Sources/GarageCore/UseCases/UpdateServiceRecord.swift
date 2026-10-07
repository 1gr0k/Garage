import Foundation

/// Правка записи об обслуживании: валидация черновика и сохранение.
public struct UpdateServiceRecord: Sendable {
    private let records: any ServiceRecordEditing

    public init(records: any ServiceRecordEditing) {
        self.records = records
    }

    /// Проверяет черновик, сохраняет `id` и `vehicleID` исходной записи.
    /// Запись и чек не изменились → репозиторий не вызывается (синхронизация не получает лишний upsert).
    /// Исходная запись сравнивается в нормализованном виде (как после `makeRecord`: обрезанные пробелы,
    /// пустой артикул → `nil`), иначе запись с пробелами в названии считалась бы изменённой.
    /// - Throws: `ServiceRecordDraft.Errors` (как есть), если черновик не прошёл проверку;
    ///   ошибки репозитория (`RepositoryError.recordNotFound` и др.).
    public func execute(draft: ServiceRecordDraft, original: ServiceRecord, receipt: ReceiptChange) async throws {
        let record = try draft.makeRecord(id: original.id, vehicleID: original.vehicleID)
        let baseline =
            (try? ServiceRecordDraft(record: original).makeRecord(id: original.id, vehicleID: original.vehicleID))
            ?? original
        if record == baseline, receipt == .keep { return }
        try await records.update(record, receipt: receipt)
    }
}
