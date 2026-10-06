import GarageCore
import GarageStorage
import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Garage", category: "Storage")

struct VehicleDetailView: View {
    @Query private var vehicleEntities: [VehicleEntity]
    @Query private var recordEntities: [ServiceRecordEntity]
    @State private var isAddingRecord = false

    init(vehicleID: Vehicle.ID) {
        _vehicleEntities = Query(filter: #Predicate { $0.id == vehicleID })
        _recordEntities = Query(ServiceRecordEntity.descriptor(forVehicle: vehicleID))
    }

    private var records: [ServiceRecord] {
        recordEntities.compactMap { entity in
            do {
                return try entity.toDomain()
            } catch {
                logger.error("Skipping invalid record \(entity.id, privacy: .public): \(error)")
                return nil
            }
        }
    }

    var body: some View {
        if let entity = vehicleEntities.first, let vehicle = try? entity.toDomain() {
            content(entity: entity, vehicle: vehicle)
        } else {
            ContentUnavailableView("Vehicle Not Found", systemImage: "questionmark.circle")
        }
    }

    private func content(entity: VehicleEntity, vehicle: Vehicle) -> some View {
        let records = records
        let mileage = vehicle.currentMileageKm(records: records)
        return List {
            Section {
                LabeledContent("Mileage", value: mileage.kilometers)
                LabeledContent("Total spent", value: records.totalCost.formatted)
            }
            Section("Service History") {
                ForEach(records) { record in
                    ServiceRecordRow(record: record, hasReceipt: hasReceipt(record.id))
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No Service Records", systemImage: "wrench.and.screwdriver")
                    .padding(.top, 120)
            }
        }
        .navigationTitle(vehicle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add Record", systemImage: "plus") { isAddingRecord = true }
        }
        .sheet(isPresented: $isAddingRecord) {
            ServiceRecordFormView(vehicle: entity, currentMileageKm: mileage)
        }
    }

    private func hasReceipt(_ id: UUID) -> Bool {
        recordEntities.first { $0.id == id }?.receiptImage != nil
    }
}

private struct ServiceRecordRow: View {
    let record: ServiceRecord
    let hasReceipt: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.serviceType.title)
                    .font(.headline)
                Text(verbatim: "\(record.date.formatted(date: .abbreviated, time: .omitted)) · \(record.mileageKm.kilometers)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !record.parts.isEmpty {
                    Text("\(record.parts.count) parts")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasReceipt {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has receipt")
            }
            Text(record.totalCost.formatted)
                .monospacedDigit()
        }
    }
}
