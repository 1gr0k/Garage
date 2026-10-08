import SwiftUI

/// Тулбар экрана машины: «Добавить запись» и меню «Ещё».
struct VehicleDetailToolbar: ToolbarContent {
    let isDeleting: Bool
    let onAddRecord: () -> Void
    let onEdit: () -> Void
    let onDeleteVehicle: () -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            Button("Add Record", systemImage: "plus", action: onAddRecord)
                .disabled(isDeleting)
                .accessibilityIdentifier(AccessibilityID.VehicleDetail.addRecord)
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Edit", systemImage: "pencil", action: onEdit)
                    .disabled(isDeleting)
                    .accessibilityIdentifier(AccessibilityID.VehicleDetail.edit)
                Button("Delete Vehicle", systemImage: "trash", role: .destructive, action: onDeleteVehicle)
                    .disabled(isDeleting)
                    .accessibilityIdentifier(AccessibilityID.VehicleDetail.deleteVehicle)
            }
            .accessibilityIdentifier(AccessibilityID.VehicleDetail.more)
        }
    }
}
