import GarageCore
import Playgrounds
import SwiftUI

struct ContentView: View {
    var vehicles: [Vehicle] = Vehicle.samples

    var body: some View {
        NavigationStack {
            List(vehicles) { vehicle in
                VStack(alignment: .leading) {
                    Text(vehicle.displayName)
                        .font(.headline)
                    Text(String(vehicle.year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if vehicles.isEmpty {
                    ContentUnavailableView("No Vehicles", systemImage: "car")
                }
            }
            .navigationTitle("Garage")
        }
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
