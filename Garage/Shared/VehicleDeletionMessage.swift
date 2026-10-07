import SwiftUI

/// Сообщение диалога удаления машины. Одним `Text`: диалог показывает только один.
/// Строка про записи — только если они есть.
struct VehicleDeletionMessage: View {
    let recordCount: Int

    var body: some View {
        if recordCount > 0 {
            Text("Its \(recordCount) service records will be deleted too. This can't be undone.")
        } else {
            Text("This can't be undone.")
        }
    }
}
