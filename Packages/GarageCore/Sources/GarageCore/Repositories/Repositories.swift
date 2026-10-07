import Foundation

/// Ошибка репозитория, не зависящая от конкретного хранилища.
public enum RepositoryError: Error, Hashable, Sendable {
    case vehicleNotFound(UUID)
}

/// Хранилище записей об обслуживании.
public protocol ServiceRecordRepository: Sendable {
    /// Сохраняет запись (и фото чека, если есть) вместе с постановкой в очередь синхронизации.
    /// - Throws: `RepositoryError.vehicleNotFound`, если машины записи нет.
    func add(_ record: ServiceRecord, receiptImage: Data?) async throws
}

/// Подготовка фото чека к хранению (уменьшение, перекодирование).
public protocol ReceiptImagePreparing: Sendable {
    func prepare(_ data: Data) async throws -> Data
}
