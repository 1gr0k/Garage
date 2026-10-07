import Foundation

/// Ошибка репозитория, не зависящая от конкретного хранилища.
public enum RepositoryError: Error, Hashable, Sendable {
    case vehicleNotFound(UUID)
    case recordNotFound(UUID)
}

/// Хранилище записей об обслуживании.
public protocol ServiceRecordRepository: Sendable {
    /// Сохраняет запись (и фото чека, если есть) вместе с постановкой в очередь синхронизации.
    /// - Throws: `RepositoryError.vehicleNotFound`, если машины записи нет.
    func add(_ record: ServiceRecord, receiptImage: Data?) async throws
}

/// Что сделать с фото чека при правке записи.
public enum ReceiptChange: Hashable, Sendable {
    /// Не трогать чек (в том числе ещё не скачанный).
    case keep
    case replace(Data)
    case remove
}

/// Правка и удаление записей об обслуживании.
public protocol ServiceRecordEditing: Sendable {
    /// Заменяет поля записи с тем же `id`; `vehicleID` не меняется.
    /// - Throws: `RepositoryError.recordNotFound`, если записи нет.
    func update(_ record: ServiceRecord, receipt: ReceiptChange) async throws
    /// Удаляет запись вместе с частями и чеком. Записи нет — не ошибка.
    func delete(id: ServiceRecord.ID) async throws
}

/// Подготовка фото чека к хранению (уменьшение, перекодирование).
public protocol ReceiptImagePreparing: Sendable {
    func prepare(_ data: Data) async throws -> Data
}
