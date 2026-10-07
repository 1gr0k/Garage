import GarageCore
import GarageStorage
import SwiftData
import SwiftUI

struct VehicleDetailView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Query private var vehicleEntities: [VehicleEntity]
    @Query private var recordEntities: [ServiceRecordEntity]
    @State private var isAddingRecord = false

    init(vehicleID: Vehicle.ID) {
        _vehicleEntities = Query(filter: #Predicate { $0.id == vehicleID })
        _recordEntities = Query(ServiceRecordEntity.descriptor(forVehicle: vehicleID))
    }

    private var receiptIDs: Set<UUID> {
        Set(recordEntities.lazy.filter(\.hasReceipt).map(\.id))
    }

    var body: some View {
        if let vehicle = vehicleEntities.validVehicles().first?.vehicle {
            content(vehicle: vehicle)
        } else {
            ContentUnavailableView("Vehicle Not Found", systemImage: "questionmark.circle")
        }
    }

    private func content(vehicle: Vehicle) -> some View {
        let records = recordEntities.validRecords()
        let receiptIDs = receiptIDs
        let mileage = vehicle.currentMileageKm(records: records)
        return List {
            Section {
                LabeledContent("Mileage", value: mileage.kilometers)
                LabeledContent("Total spent", value: records.totalCost.formatted)
            }
            Section("Service History") {
                ForEach(records) { record in
                    ServiceRecordRow(record: record, hasReceipt: receiptIDs.contains(record.id))
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
            ServiceRecordFormView(
                viewModel: dependencies.makeServiceRecordFormViewModel(
                    vehicleID: vehicle.id, currentMileageKm: mileage))
        }
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
                Text(
                    verbatim:
                        "\(record.date.formatted(date: .abbreviated, time: .omitted)) · \(record.mileageKm.kilometers)"
                )
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
