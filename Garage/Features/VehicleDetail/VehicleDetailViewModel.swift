import Foundation
import GarageCore
import Observation

/// Состояние экрана машины: удаление записи из списка (подтверждение и сбой).
@Observable
final class VehicleDetailViewModel {
    /// Запись, для которой показан диалог подтверждения; `nil` — диалога нет (в том числе после отмены).
    var pendingDeletion: ServiceRecord.ID?
    /// Привязан к алерту вью, поэтому изменяем снаружи.
    var deleteFailed = false
    private(set) var isDeleting = false

    private let records: any ServiceRecordEditing

    init(records: any ServiceRecordEditing) {
        self.records = records
    }

    /// Удаляет подтверждённую запись. `id` передаёт вью из диалога: к моменту старта задачи
    /// `pendingDeletion` уже может быть сброшен закрытием диалога.
    func delete(id: ServiceRecord.ID) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        pendingDeletion = nil
        do {
            try await records.delete(id: id)
        } catch {
            deleteFailed = true
        }
    }
}
