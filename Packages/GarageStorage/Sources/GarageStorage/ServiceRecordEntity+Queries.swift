import Foundation
import SwiftData

extension ServiceRecordEntity {
    /// A vehicle's records, newest first (ties broken by higher mileage).
    public static func descriptor(forVehicle vehicleID: UUID) -> FetchDescriptor<ServiceRecordEntity> {
        FetchDescriptor(
            predicate: #Predicate { $0.vehicle?.id == vehicleID },
            sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.mileageKm, order: .reverse)]
        )
    }
}
