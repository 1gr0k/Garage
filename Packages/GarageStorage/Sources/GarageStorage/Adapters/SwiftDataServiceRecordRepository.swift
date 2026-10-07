import Foundation
import GarageCore
import SwiftData

/// `ServiceRecordRepository` поверх SwiftData. Очередь синхронизации ведёт `ServiceLog.add`.
public struct SwiftDataServiceRecordRepository: ServiceRecordRepository {
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
}

/// `ReceiptImagePreparing` через ImageIO; тяжёлая работа идёт вне вызывающего актора.
public struct ImageIOReceiptPreparer: ReceiptImagePreparing {
    public init() {}

    @concurrent
    public func prepare(_ data: Data) async throws -> Data {
        try ReceiptImage.prepare(data)
    }
}
