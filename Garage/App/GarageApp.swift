import SwiftUI

@main struct GarageApp: App {
    @State private var launchModel = LaunchModel(bootstrap: AppDependencies.launchBootstrap)

    var body: some Scene {
        WindowGroup {
            RootView(launchModel: launchModel)
        }
    }
}
