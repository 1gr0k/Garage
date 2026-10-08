import Foundation
import GarageAPI

/// A stored entity that cannot be mapped to (or from) the domain model.
public enum StorageMappingError: Error, Equatable, Sendable {
    case unknownVehicleKind(String)
    case missingVehicle(UUID)
    case vehicleMismatch(expected: UUID, actual: UUID)
    /// Вид сущности синхронизации, который это хранилище ещё не умеет сохранять (правила обслуживания до части B).
    case unsupportedEntity(EntityKind)
}
