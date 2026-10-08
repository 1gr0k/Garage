import SwiftData
import SwiftUI

/// Корневой экран: загрузка → список или ошибка запуска с кнопкой «Повторить».
struct RootView: View {
    let launchModel: LaunchModel
    @State private var attempt = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch launchModel.state {
            case .loading:
                ProgressView()
            case .ready(let dependencies):
                VehicleListView()
                    .modelContainer(dependencies.container)
                    .environment(dependencies)
                    .environment(dependencies.syncViewModel)
                    // Прошло время, окно лимита сдвинулось, пользователь мог включить уведомления в Настройках.
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { dependencies.reminderCoordinator.appBecameActive() }
                    }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Open Garage", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The garage data could not be loaded.")
                    Text(verbatim: message)
                } actions: {
                    Button("Retry") { attempt += 1 }
                }
            }
        }
        .task(id: attempt) { await launchModel.launch() }
    }
}
