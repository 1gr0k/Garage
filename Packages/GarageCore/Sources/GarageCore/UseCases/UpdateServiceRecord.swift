import Foundation

/// Правка записи об обслуживании: валидация черновика и сохранение.
public struct UpdateServiceRecord: Sendable {
    private let records: any ServiceRecordEditing

    public init(records: any ServiceRecordEditing) {
        self.records = records
    }

    /// Проверяет черновик, сохраняет `id` и `vehicleID` исходной записи.
    /// Запись и чек не изменились → репозиторий не вызывается (синхронизация не получает лишний upsert).
    /// - Throws: `ServiceRecordDraft.Errors` (как есть), если черновик не прошёл проверку;
    ///   ошибки репозитория (`RepositoryError.recordNotFound` и др.).
    public func execute(draft: ServiceRecordDraft, original: ServiceRecord, receipt: ReceiptChange) async throws {
        let record = try draft.makeRecord(id: original.id, vehicleID: original.vehicleID)
        if record == original, receipt == .keep { return }
        try await records.update(record, receipt: receipt)
    }
}
