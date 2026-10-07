import SwiftUI

@main struct GarageApp: App {
    @State private var launchModel = LaunchModel(bootstrap: AppDependencies.bootstrap)

    var body: some Scene {
        WindowGroup {
            RootView(launchModel: launchModel)
        }
    }
}
