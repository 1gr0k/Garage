import Foundation

/// Добавление записи об обслуживании: валидация черновика и сохранение.
public struct AddServiceRecord: Sendable {
    private let records: any ServiceRecordRepository

    public init(records: any ServiceRecordRepository) {
        self.records = records
    }

    /// - Throws: `ServiceRecordDraft.Errors` (как есть), если черновик не прошёл проверку;
    ///   ошибки репозитория (`RepositoryError.vehicleNotFound` и др.).
    public func execute(draft: ServiceRecordDraft, vehicleID: Vehicle.ID, receipt: Data?) async throws {
        let record = try draft.makeRecord(vehicleID: vehicleID)
        try await records.add(record, receiptImage: receipt)
    }
}
