import Foundation
import GarageCore
import SwiftData

/// `ServiceRecordRepository` и `ServiceRecordEditing` поверх SwiftData. Очередь синхронизации ведут
/// `ServiceLog.add` / `update` / `delete`.
public struct SwiftDataServiceRecordRepository: ServiceRecordRepository, ServiceRecordEditing {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func add(_ record: ServiceRecord, receiptImage: Data?) async throws {
        do {
            try ServiceLog.add(record, receiptImage: receiptImage, toVehicleWithID: record.vehicleID, in: container)
        } catch ServiceLogError.vehicleNotFound(let id) {
            throw RepositoryError.vehicleNotFound(id)
        }
    }

    public func update(_ record: ServiceRecord, receipt: ReceiptChange) async throws {
        do {
            try ServiceLog.update(record, receipt: receipt, in: container)
        } catch ServiceLogError.recordNotFound(let id) {
            throw RepositoryError.recordNotFound(id)
        }
    }

    public func delete(id: ServiceRecord.ID) async throws {
        try ServiceLog.delete(id: id, in: container)
    }
}

/// `ReceiptImagePreparing` через ImageIO; тяжёлая работа идёт вне вызывающего актора.
public struct ImageIOReceiptPreparer: ReceiptImagePreparing {
    public init() {}

    @concurrent
    public func prepare(_ data: Data) async throws -> Data {
        try ReceiptImage.prepare(data)
    }
}
