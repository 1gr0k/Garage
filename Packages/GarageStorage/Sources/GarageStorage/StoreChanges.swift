import Foundation
import SwiftData

/// Сигнал «данные в хранилище сохранены» (решение 15 плана этапа 12).
///
/// `ModelContext.didSave` приходит от **всех** сохранений контейнера: свежих контекстов `ServiceLog` / `VehicleLog` /
/// `RuleLog`, `ModelActor` синхронизации, адаптеров и `mainContext` (проба 0.7). Приходит на потоке сохранявшего,
/// поэтому подписчик сам переходит на нужный актор. Сигнал дают и служебные сохранения синхронизации (курсор,
/// версии) — склеивает их дебаунс подписчика.
public enum StoreChanges {
    /// Поток сигналов, по одному на сохранение контекста этого контейнера. Подписка живёт, пока жив поток.
    public static func saves(of container: ModelContainer) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observer = ObserverBox()
            observer.token = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave, object: nil, queue: nil
            ) { notification in
                guard let context = notification.object as? ModelContext, context.container === container else {
                    return
                }
                continuation.yield()
            }
            continuation.onTermination = { _ in
                if let token = observer.token { NotificationCenter.default.removeObserver(token) }
            }
        }
    }

    /// `addObserver` отдаёт несендаблный токен; снимается он один раз, из `onTermination`.
    private final class ObserverBox: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
    }
}
