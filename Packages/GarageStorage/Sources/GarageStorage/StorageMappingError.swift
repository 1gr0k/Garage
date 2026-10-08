import Foundation

/// A stored entity that cannot be mapped to (or from) the domain model.
public enum StorageMappingError: Error, Equatable, Sendable {
    case unknownVehicleKind(String)
    case missingVehicle(UUID)
    case vehicleMismatch(expected: UUID, actual: UUID)
}
