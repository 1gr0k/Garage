import GarageCore
import SwiftUI

/// История обслуживания: строки записей и свайп «Удалить». Состояние подтверждения (`pendingDeletion`) живёт
/// во ViewModel экрана, секция получает действия замыканиями.
struct ServiceHistorySection: View {
    let records: [ServiceRecord]
    let receiptIDs: Set<UUID>
    let isDeleting: Bool
    let onOpen: (ServiceRecord.ID) -> Void
    let onDelete: (ServiceRecord.ID) -> Void

    var body: some View {
        Section("Service History") {
            ForEach(records) { record in
                Button {
                    onOpen(record.id)
                } label: {
                    ServiceRecordRow(record: record, hasReceipt: receiptIDs.contains(record.id))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.VehicleDetail.record(record.id))
                // Без `role: .destructive`: иначе List уберёт строку ещё до подтверждения.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete") { onDelete(record.id) }
                        .tint(.red)
                        .disabled(isDeleting)
                        .accessibilityIdentifier(AccessibilityID.VehicleDetail.swipeDeleteRecord)
                }
            }
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
                    .accessibilityIdentifier(AccessibilityID.VehicleDetail.receiptClip(record.id))
            }
            Text(record.totalCost.formatted)
                .monospacedDigit()
        }
    }
}
