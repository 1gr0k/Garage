import SwiftData

public enum GarageStore {
    public static let models: [any PersistentModel.Type] = [
        VehicleEntity.self, ServiceRecordEntity.self, PartEntity.self,
    ]

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
